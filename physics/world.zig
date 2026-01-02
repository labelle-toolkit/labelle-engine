//! Physics World
//!
//! Wraps the Box2D physics world and manages entity <-> body mappings.
//! All physics runtime state is stored here, keeping ECS components clean.
//!
//! Uses HashMap for O(1) lookups with arbitrary entity IDs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const components = @import("components.zig");
const RigidBody = components.RigidBody;
const Collider = components.Collider;
const BodyType = components.BodyType;

// Box2D bindings
const box2d = @import("box2d/adapter.zig");

/// Collision event between two entities
pub const CollisionEvent = struct {
    /// First entity in the collision
    entity_a: u64,
    /// Second entity in the collision
    entity_b: u64,
    /// World-space contact point
    contact_point: [2]f32,
    /// Contact normal (points from A to B)
    normal: [2]f32,
    /// Collision impulse magnitude
    impulse: f32,
};

/// Sensor overlap event
pub const SensorEvent = struct {
    /// The sensor entity
    sensor_entity: u64,
    /// The entity that entered/exited the sensor
    other_entity: u64,
};

/// Fixture list for an entity (up to 8 fixtures per entity)
pub const FixtureList = struct {
    fixtures: [8]box2d.FixtureId = undefined,
    count: u8 = 0,

    pub fn add(self: *FixtureList, fixture: box2d.FixtureId) void {
        if (self.count < 8) {
            self.fixtures[self.count] = fixture;
            self.count += 1;
        }
    }

    pub fn slice(self: *const FixtureList) []const box2d.FixtureId {
        return self.fixtures[0..self.count];
    }
};

/// Default max entities (can be configured)
pub const DEFAULT_MAX_ENTITIES: usize = 100_000;

/// Physics world wrapper
///
/// Manages the Box2D world and all entity <-> body mappings.
/// Collision events are buffered each step and queryable via the event accessors.
///
/// Uses HashMap for O(1) lookups with arbitrary entity IDs.
pub const PhysicsWorld = struct {
    allocator: Allocator,

    /// Underlying Box2D world
    world: box2d.World,

    // Entity <-> Body mappings using HashMap (O(1) lookup, handles arbitrary entity IDs)
    body_map: std.AutoHashMap(u64, box2d.BodyId),        // entity -> body_id
    entity_map: std.AutoHashMap(u64, u64),               // body_id (as u64) -> entity
    fixture_map: std.AutoHashMap(u64, FixtureList),      // entity -> fixtures
    entity_list: std.ArrayList(u64),                      // for iteration

    // Collision event buffers (cleared each step)
    collision_begin_events: std.ArrayList(CollisionEvent),
    collision_end_events: std.ArrayList(CollisionEvent),
    sensor_enter_events: std.ArrayList(SensorEvent),
    sensor_exit_events: std.ArrayList(SensorEvent),

    // Simulation parameters
    time_step: f32,
    velocity_iterations: i32,
    position_iterations: i32,
    accumulator: f32,

    /// Pixels per meter scale (Box2D works best with meters)
    pixels_per_meter: f32,

    /// Initialize physics world
    ///
    /// gravity: World gravity in pixels/sec² (will be converted to meters internally)
    pub fn init(allocator: Allocator, gravity: [2]f32) !PhysicsWorld {
        return initWithConfig(allocator, gravity, .{});
    }

    pub const Config = struct {
        /// Physics time step (default: 1/60 second for 60 FPS)
        time_step: f32 = 1.0 / 60.0,
        /// Velocity solver iterations (higher = more accurate but slower)
        velocity_iterations: i32 = 8,
        /// Position solver iterations
        position_iterations: i32 = 3,
        /// Pixels per meter conversion (Box2D uses meters internally)
        pixels_per_meter: f32 = 100.0,
    };

    /// Initialize with custom configuration
    pub fn initWithConfig(allocator: Allocator, gravity: [2]f32, config: Config) !PhysicsWorld {
        // Convert gravity from pixels to meters
        const gravity_meters: [2]f32 = .{
            gravity[0] / config.pixels_per_meter,
            gravity[1] / config.pixels_per_meter,
        };

        return PhysicsWorld{
            .allocator = allocator,
            .world = try box2d.World.init(gravity_meters),
            .body_map = std.AutoHashMap(u64, box2d.BodyId).init(allocator),
            .entity_map = std.AutoHashMap(u64, u64).init(allocator),
            .fixture_map = std.AutoHashMap(u64, FixtureList).init(allocator),
            .entity_list = .{},
            .collision_begin_events = .{},
            .collision_end_events = .{},
            .sensor_enter_events = .{},
            .sensor_exit_events = .{},
            .time_step = config.time_step,
            .velocity_iterations = config.velocity_iterations,
            .position_iterations = config.position_iterations,
            .accumulator = 0,
            .pixels_per_meter = config.pixels_per_meter,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *PhysicsWorld) void {
        self.body_map.deinit();
        self.entity_map.deinit();
        self.fixture_map.deinit();
        self.entity_list.deinit(self.allocator);
        self.collision_begin_events.deinit(self.allocator);
        self.collision_end_events.deinit(self.allocator);
        self.sensor_enter_events.deinit(self.allocator);
        self.sensor_exit_events.deinit(self.allocator);
        self.world.deinit();
    }

    /// Check if entity has a physics body
    pub fn hasBody(self: *const PhysicsWorld, entity: u64) bool {
        return self.body_map.contains(entity);
    }

    /// Get body ID for entity (if exists)
    pub fn getBodyId(self: *const PhysicsWorld, entity: u64) ?box2d.BodyId {
        return self.body_map.get(entity);
    }

    /// Get entity for body ID (if exists)
    pub fn getEntity(self: *const PhysicsWorld, body_id: box2d.BodyId) ?u64 {
        // Convert BodyId to u64 for lookup
        const body_key = bodyIdToU64(body_id);
        return self.entity_map.get(body_key);
    }

    /// Get number of physics bodies
    pub fn bodyCount(self: *const PhysicsWorld) usize {
        return self.body_map.count();
    }

    /// Iterate over all entities with physics bodies
    pub fn entities(self: *const PhysicsWorld) []const u64 {
        return self.entity_list.items;
    }

    /// Create physics body for entity
    ///
    /// position: Entity position in pixels
    pub fn createBody(
        self: *PhysicsWorld,
        entity: u64,
        rigid_body: RigidBody,
        position: struct { x: f32, y: f32 },
    ) !void {
        // Don't create duplicate bodies
        if (self.hasBody(entity)) return;

        // Convert position to meters
        const pos_meters: [2]f32 = .{
            position.x / self.pixels_per_meter,
            position.y / self.pixels_per_meter,
        };

        // Create body definition
        const body_def = box2d.BodyDef{
            .body_type = switch (rigid_body.body_type) {
                .static => .static,
                .kinematic => .kinematic,
                .dynamic => .dynamic,
            },
            .position = pos_meters,
            .angle = 0,
            .linear_damping = rigid_body.linear_damping,
            .angular_damping = rigid_body.angular_damping,
            .gravity_scale = rigid_body.gravity_scale,
            .fixed_rotation = rigid_body.fixed_rotation,
            .bullet = rigid_body.bullet,
            .awake = rigid_body.awake,
            .allow_sleep = rigid_body.allow_sleep,
        };

        // Create body
        const body_id = try self.world.createBody(body_def);

        // Store mappings using HashMap
        try self.body_map.put(entity, body_id);
        try self.entity_map.put(bodyIdToU64(body_id), entity);
        try self.fixture_map.put(entity, FixtureList{});
        try self.entity_list.append(self.allocator, entity);
    }

    /// Add collider to entity's physics body
    pub fn addCollider(self: *PhysicsWorld, entity: u64, collider: Collider) !void {
        const body_id = self.body_map.get(entity) orelse return error.NoBody;

        // Convert shape to Box2D format (pixels to meters)
        const shape = self.convertShape(collider.shape);

        const fixture_def = box2d.FixtureDef{
            .shape = shape,
            .density = collider.density,
            .friction = collider.friction,
            .restitution = collider.restitution,
            .restitution_threshold = collider.restitution_threshold,
            .is_sensor = collider.is_sensor,
            .filter = .{
                .category_bits = collider.category_bits,
                .mask_bits = collider.mask_bits,
                .group_index = collider.group_index,
            },
        };

        const fixture_id = try self.world.createFixture(body_id, fixture_def);

        // Store fixture in the FixtureList
        if (self.fixture_map.getPtr(entity)) |fixture_list| {
            fixture_list.add(fixture_id);
        }
    }

    /// Remove physics body for entity
    pub fn destroyBody(self: *PhysicsWorld, entity: u64) void {
        if (self.body_map.get(entity)) |body_id| {
            // Remove from entity_map first
            _ = self.entity_map.remove(bodyIdToU64(body_id));
            // Destroy the Box2D body
            self.world.destroyBody(body_id);
        }

        // Remove from body_map
        _ = self.body_map.remove(entity);
        // Remove fixtures list
        _ = self.fixture_map.remove(entity);

        // Remove from entity list
        for (self.entity_list.items, 0..) |e, i| {
            if (e == entity) {
                _ = self.entity_list.swapRemove(i);
                break;
            }
        }
    }

    /// Step physics simulation with fixed timestep accumulator
    pub fn update(self: *PhysicsWorld, dt: f32) void {
        // Clear event buffers
        self.collision_begin_events.clearRetainingCapacity();
        self.collision_end_events.clearRetainingCapacity();
        self.sensor_enter_events.clearRetainingCapacity();
        self.sensor_exit_events.clearRetainingCapacity();

        // Fixed timestep accumulator
        self.accumulator += dt;
        while (self.accumulator >= self.time_step) {
            self.world.step(
                self.time_step,
                self.velocity_iterations,
                self.position_iterations,
            );
            self.processCollisionEvents();
            self.accumulator -= self.time_step;
        }
    }

    /// Get interpolation alpha for smooth rendering between physics steps
    pub fn getInterpolationAlpha(self: *const PhysicsWorld) f32 {
        return self.accumulator / self.time_step;
    }

    /// Get body position in pixels
    pub fn getPosition(self: *PhysicsWorld, entity: u64) ?[2]f32 {
        const body_id = self.body_map.get(entity) orelse return null;
        const pos_meters = self.world.getPosition(body_id);
        return .{
            pos_meters[0] * self.pixels_per_meter,
            pos_meters[1] * self.pixels_per_meter,
        };
    }

    /// Get body rotation in radians
    pub fn getAngle(self: *PhysicsWorld, entity: u64) ?f32 {
        const body_id = self.body_map.get(entity) orelse return null;
        return self.world.getAngle(body_id);
    }

    /// Get body linear velocity in pixels/sec
    pub fn getLinearVelocity(self: *const PhysicsWorld, entity: u64) ?[2]f32 {
        const body_id = self.body_map.get(entity) orelse return null;
        const vel_meters = self.world.getLinearVelocity(body_id);
        return .{
            vel_meters[0] * self.pixels_per_meter,
            vel_meters[1] * self.pixels_per_meter,
        };
    }

    /// Set body linear velocity in pixels/sec
    pub fn setLinearVelocity(self: *PhysicsWorld, entity: u64, velocity: [2]f32) void {
        const body_id = self.body_map.get(entity) orelse return;
        self.world.setLinearVelocity(body_id, .{
            velocity[0] / self.pixels_per_meter,
            velocity[1] / self.pixels_per_meter,
        });
    }

    /// Apply impulse at center of mass (pixels * kg / sec)
    pub fn applyLinearImpulse(self: *PhysicsWorld, entity: u64, impulse: [2]f32) void {
        const body_id = self.body_map.get(entity) orelse return;
        self.world.applyLinearImpulse(body_id, .{
            impulse[0] / self.pixels_per_meter,
            impulse[1] / self.pixels_per_meter,
        });
    }

    /// Apply force at center of mass (pixels * kg / sec²)
    pub fn applyForce(self: *PhysicsWorld, entity: u64, force: [2]f32) void {
        const body_id = self.body_map.get(entity) orelse return;
        self.world.applyForce(body_id, .{
            force[0] / self.pixels_per_meter,
            force[1] / self.pixels_per_meter,
        });
    }

    // Event queries

    /// Get collision begin events from last physics step
    pub fn getCollisionBeginEvents(self: *const PhysicsWorld) []const CollisionEvent {
        return self.collision_begin_events.items;
    }

    /// Get collision end events from last physics step
    pub fn getCollisionEndEvents(self: *const PhysicsWorld) []const CollisionEvent {
        return self.collision_end_events.items;
    }

    /// Get sensor enter events from last physics step
    pub fn getSensorEnterEvents(self: *const PhysicsWorld) []const SensorEvent {
        return self.sensor_enter_events.items;
    }

    /// Get sensor exit events from last physics step
    pub fn getSensorExitEvents(self: *const PhysicsWorld) []const SensorEvent {
        return self.sensor_exit_events.items;
    }

    // Internal helpers

    fn convertShape(self: *const PhysicsWorld, shape: components.Shape) box2d.Shape {
        const ppm = self.pixels_per_meter;
        return switch (shape) {
            .box => |b| .{ .box = .{
                .half_width = (b.width / 2) / ppm,
                .half_height = (b.height / 2) / ppm,
            } },
            .circle => |c| .{ .circle = .{ .radius = c.radius / ppm } },
            .edge => |e| .{ .edge = .{
                .start = .{ e.start[0] / ppm, e.start[1] / ppm },
                .end = .{ e.end[0] / ppm, e.end[1] / ppm },
            } },
            .polygon => |p| blk: {
                // Convert vertices to meters
                var vertices: [8][2]f32 = undefined;
                const count = @min(p.vertices.len, 8);
                for (0..count) |i| {
                    vertices[i] = .{
                        p.vertices[i][0] / ppm,
                        p.vertices[i][1] / ppm,
                    };
                }
                break :blk .{ .polygon = .{
                    .vertices = vertices[0..count],
                } };
            },
            .chain => |c| blk: {
                _ = c;
                // TODO: Implement chain shape conversion
                break :blk .{ .box = .{ .half_width = 1, .half_height = 1 } };
            },
        };
    }

    fn processCollisionEvents(self: *PhysicsWorld) void {
        // Get contact events from Box2D and convert to our format
        var contact_iter = self.world.getContactEvents();
        while (contact_iter.next()) |contact| {
            const entity_a = self.entity_map.get(bodyIdToU64(contact.body_a)) orelse continue;
            const entity_b = self.entity_map.get(bodyIdToU64(contact.body_b)) orelse continue;

            const event = CollisionEvent{
                .entity_a = entity_a,
                .entity_b = entity_b,
                .contact_point = .{
                    contact.point[0] * self.pixels_per_meter,
                    contact.point[1] * self.pixels_per_meter,
                },
                .normal = contact.normal,
                .impulse = contact.impulse * self.pixels_per_meter,
            };

            if (contact.is_begin) {
                self.collision_begin_events.append(self.allocator, event) catch {};
            } else {
                self.collision_end_events.append(self.allocator, event) catch {};
            }
        }

        // Get sensor events
        var sensor_iter = self.world.getSensorEvents();
        while (sensor_iter.next()) |sensor| {
            const sensor_entity = self.entity_map.get(bodyIdToU64(sensor.sensor_body)) orelse continue;
            const other_entity = self.entity_map.get(bodyIdToU64(sensor.other_body)) orelse continue;

            const event = SensorEvent{
                .sensor_entity = sensor_entity,
                .other_entity = other_entity,
            };

            if (sensor.is_enter) {
                self.sensor_enter_events.append(self.allocator, event) catch {};
            } else {
                self.sensor_exit_events.append(self.allocator, event) catch {};
            }
        }
    }
};

/// Convert BodyId to u64 for use as SparseSet key
/// Box2D's BodyId is typically an index or handle that can be represented as u64
fn bodyIdToU64(body_id: box2d.BodyId) u64 {
    // BodyId is a struct with index fields - convert to unique u64
    // This depends on Box2D's actual BodyId structure
    return @bitCast(body_id);
}
