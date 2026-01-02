//! Box2D Adapter
//!
//! Wraps the Box2D C API with a Zig-friendly interface.
//! Uses allyourcodebase/box2d bindings.

const std = @import("std");
const c = @cImport({
    @cInclude("box2d/box2d.h");
});

/// Opaque body identifier
pub const BodyId = c.b2BodyId;

/// Opaque fixture identifier
pub const FixtureId = c.b2ShapeId;

/// Body type
pub const BodyType = enum {
    static,
    kinematic,
    dynamic,

    fn toC(self: BodyType) c.b2BodyType {
        return switch (self) {
            .static => c.b2_staticBody,
            .kinematic => c.b2_kinematicBody,
            .dynamic => c.b2_dynamicBody,
        };
    }
};

/// Body definition
pub const BodyDef = struct {
    body_type: BodyType = .dynamic,
    position: [2]f32 = .{ 0, 0 },
    angle: f32 = 0,
    linear_damping: f32 = 0,
    angular_damping: f32 = 0,
    gravity_scale: f32 = 1,
    fixed_rotation: bool = false,
    bullet: bool = false,
    awake: bool = true,
    allow_sleep: bool = true,
};

/// Shape types
pub const Shape = union(enum) {
    box: struct {
        half_width: f32,
        half_height: f32,
    },
    circle: struct {
        radius: f32,
    },
    edge: struct {
        start: [2]f32,
        end: [2]f32,
    },
    polygon: struct {
        vertices: []const [2]f32,
    },
};

/// Collision filter
pub const Filter = struct {
    category_bits: u16 = 0x0001,
    mask_bits: u16 = 0xFFFF,
    group_index: i16 = 0,
};

/// Fixture definition
pub const FixtureDef = struct {
    shape: Shape,
    density: f32 = 1.0,
    friction: f32 = 0.3,
    restitution: f32 = 0.0,
    restitution_threshold: f32 = 1.0,
    is_sensor: bool = false,
    filter: Filter = .{},
};

/// Contact event from Box2D
pub const ContactEvent = struct {
    body_a: BodyId,
    body_b: BodyId,
    point: [2]f32,
    normal: [2]f32,
    impulse: f32,
    is_begin: bool,
};

/// Sensor event from Box2D
pub const SensorEventData = struct {
    sensor_body: BodyId,
    other_body: BodyId,
    is_enter: bool,
};

/// Contact event iterator
pub const ContactEventIterator = struct {
    world: *World,
    index: usize = 0,

    pub fn next(self: *ContactEventIterator) ?ContactEvent {
        // TODO: Implement actual Box2D contact iteration
        _ = self;
        return null;
    }
};

/// Sensor event iterator
pub const SensorEventIterator = struct {
    world: *World,
    index: usize = 0,

    pub fn next(self: *SensorEventIterator) ?SensorEventData {
        // TODO: Implement actual Box2D sensor iteration
        _ = self;
        return null;
    }
};

/// Box2D World wrapper
pub const World = struct {
    world_id: c.b2WorldId,

    /// Initialize a new physics world
    pub fn init(gravity: [2]f32) !World {
        var world_def = c.b2DefaultWorldDef();
        world_def.gravity = .{ .x = gravity[0], .y = gravity[1] };

        const world_id = c.b2CreateWorld(&world_def);
        if (!c.b2World_IsValid(world_id)) {
            return error.FailedToCreateWorld;
        }

        return World{ .world_id = world_id };
    }

    /// Clean up world resources
    pub fn deinit(self: *World) void {
        c.b2DestroyWorld(self.world_id);
    }

    /// Step the physics simulation
    pub fn step(self: *World, time_step: f32, sub_step_count: i32, _: i32) void {
        c.b2World_Step(self.world_id, time_step, sub_step_count);
    }

    /// Create a physics body
    pub fn createBody(self: *World, def: BodyDef) !BodyId {
        var body_def = c.b2DefaultBodyDef();
        body_def.type = def.body_type.toC();
        body_def.position = .{ .x = def.position[0], .y = def.position[1] };
        body_def.rotation = c.b2MakeRot(def.angle);
        body_def.linearDamping = def.linear_damping;
        body_def.angularDamping = def.angular_damping;
        body_def.gravityScale = def.gravity_scale;
        body_def.fixedRotation = def.fixed_rotation;
        body_def.isBullet = def.bullet;
        body_def.isAwake = def.awake;
        body_def.enableSleep = def.allow_sleep;

        const body_id = c.b2CreateBody(self.world_id, &body_def);
        if (!c.b2Body_IsValid(body_id)) {
            return error.FailedToCreateBody;
        }

        return body_id;
    }

    /// Destroy a physics body
    pub fn destroyBody(self: *World, body_id: BodyId) void {
        _ = self;
        if (c.b2Body_IsValid(body_id)) {
            c.b2DestroyBody(body_id);
        }
    }

    /// Create a fixture/shape on a body
    pub fn createFixture(self: *World, body_id: BodyId, def: FixtureDef) !FixtureId {
        _ = self;

        var shape_def = c.b2DefaultShapeDef();
        shape_def.density = def.density;
        shape_def.friction = def.friction;
        shape_def.restitution = def.restitution;
        shape_def.isSensor = def.is_sensor;
        shape_def.filter.categoryBits = def.filter.category_bits;
        shape_def.filter.maskBits = def.filter.mask_bits;
        shape_def.filter.groupIndex = def.filter.group_index;

        const shape_id = switch (def.shape) {
            .box => |box| blk: {
                const polygon = c.b2MakeBox(box.half_width, box.half_height);
                break :blk c.b2CreatePolygonShape(body_id, &shape_def, &polygon);
            },
            .circle => |circle| blk: {
                const circle_shape = c.b2Circle{
                    .center = .{ .x = 0, .y = 0 },
                    .radius = circle.radius,
                };
                break :blk c.b2CreateCircleShape(body_id, &shape_def, &circle_shape);
            },
            .edge => |edge| blk: {
                const segment = c.b2Segment{
                    .point1 = .{ .x = edge.start[0], .y = edge.start[1] },
                    .point2 = .{ .x = edge.end[0], .y = edge.end[1] },
                };
                break :blk c.b2CreateSegmentShape(body_id, &shape_def, &segment);
            },
            .polygon => |poly| blk: {
                if (poly.vertices.len < 3 or poly.vertices.len > 8) {
                    return error.InvalidPolygon;
                }

                var points: [8]c.b2Vec2 = undefined;
                for (poly.vertices, 0..) |v, i| {
                    points[i] = .{ .x = v[0], .y = v[1] };
                }

                const hull = c.b2ComputeHull(&points, @intCast(poly.vertices.len));
                const polygon = c.b2MakePolygon(&hull, 0);
                break :blk c.b2CreatePolygonShape(body_id, &shape_def, &polygon);
            },
        };

        if (!c.b2Shape_IsValid(shape_id)) {
            return error.FailedToCreateShape;
        }

        return shape_id;
    }

    /// Get body position
    pub fn getPosition(self: *World, body_id: BodyId) [2]f32 {
        _ = self;
        const pos = c.b2Body_GetPosition(body_id);
        return .{ pos.x, pos.y };
    }

    /// Get body angle
    pub fn getAngle(self: *World, body_id: BodyId) f32 {
        _ = self;
        const rot = c.b2Body_GetRotation(body_id);
        return c.b2Rot_GetAngle(rot);
    }

    /// Set body transform
    pub fn setTransform(self: *World, body_id: BodyId, position: [2]f32, angle: f32) void {
        _ = self;
        c.b2Body_SetTransform(body_id, .{ .x = position[0], .y = position[1] }, c.b2MakeRot(angle));
    }

    /// Get linear velocity
    pub fn getLinearVelocity(self: *World, body_id: BodyId) [2]f32 {
        _ = self;
        const vel = c.b2Body_GetLinearVelocity(body_id);
        return .{ vel.x, vel.y };
    }

    /// Set linear velocity
    pub fn setLinearVelocity(self: *World, body_id: BodyId, velocity: [2]f32) void {
        _ = self;
        c.b2Body_SetLinearVelocity(body_id, .{ .x = velocity[0], .y = velocity[1] });
    }

    /// Apply impulse at center of mass
    pub fn applyLinearImpulse(self: *World, body_id: BodyId, impulse: [2]f32) void {
        _ = self;
        c.b2Body_ApplyLinearImpulseToCenter(body_id, .{ .x = impulse[0], .y = impulse[1] }, true);
    }

    /// Apply force at center of mass
    pub fn applyForce(self: *World, body_id: BodyId, force: [2]f32) void {
        _ = self;
        c.b2Body_ApplyForceToCenter(body_id, .{ .x = force[0], .y = force[1] }, true);
    }

    /// Get contact events iterator
    pub fn getContactEvents(self: *World) ContactEventIterator {
        return .{ .world = self };
    }

    /// Get sensor events iterator
    pub fn getSensorEvents(self: *World) SensorEventIterator {
        return .{ .world = self };
    }
};
