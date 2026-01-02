//! Physics Systems
//!
//! ECS systems for physics simulation. These integrate the physics world
//! with the ECS registry, handling body creation, synchronization, and cleanup.

const std = @import("std");
const PhysicsWorld = @import("world.zig").PhysicsWorld;
const components = @import("components.zig");
const RigidBody = components.RigidBody;
const Collider = components.Collider;
const Velocity = components.Velocity;

/// Initialize physics bodies for new entities with RigidBody + Position components.
///
/// Call this each frame before the physics update to handle newly created entities.
/// Entities that already have physics bodies are skipped.
///
/// Example:
/// ```zig
/// physics.systems.initBodies(&physics_world, registry);
/// ```
pub fn initBodies(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    // Query for entities with RigidBody and Position
    var query = registry.query(.{ RigidBody, @TypeOf(registry).Position });
    while (query.next()) |item| {
        const entity = entityToU64(item.entity);

        // Skip if already has physics body
        if (world.hasBody(entity)) continue;

        const rb = item.get(RigidBody);
        const pos = item.get(@TypeOf(registry).Position);

        world.createBody(entity, rb.*, .{ .x = pos.x, .y = pos.y }) catch |err| {
            std.log.err("Failed to create physics body for entity {}: {}", .{ entity, err });
            continue;
        };

        // Add collider if present
        if (registry.tryGet(item.entity, Collider)) |collider| {
            world.addCollider(entity, collider.*) catch |err| {
                std.log.err("Failed to add collider for entity {}: {}", .{ entity, err });
            };
        }
    }
}

/// Clean up physics bodies for destroyed entities.
///
/// Call this after entity destruction to remove orphaned physics bodies.
/// Alternatively, integrate with entity_destroyed hook.
pub fn cleanupBodies(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    // Iterate over all physics bodies and check if entity still exists
    var entities_to_remove = std.ArrayList(u64).init(world.allocator);
    defer entities_to_remove.deinit();

    var iter = world.body_map.keyIterator();
    while (iter.next()) |entity| {
        // Check if entity exists in registry
        const ecs_entity = entityFromU64(entity.*, @TypeOf(registry).Entity);
        if (!registry.isValid(ecs_entity)) {
            entities_to_remove.append(entity.*) catch continue;
        }
    }

    // Remove orphaned bodies
    for (entities_to_remove.items) |entity| {
        world.destroyBody(entity);
    }
}

/// Main physics update system.
///
/// Steps the physics simulation and syncs results back to ECS Position components.
/// Uses fixed timestep internally for deterministic simulation.
///
/// Example:
/// ```zig
/// physics.systems.update(&physics_world, registry, dt);
/// ```
pub fn update(
    world: *PhysicsWorld,
    registry: anytype,
    dt: f32,
) void {
    // 1. Sync kinematic bodies from ECS -> Physics
    syncKinematicBodies(world, registry);

    // 2. Sync velocity components to physics (if used)
    syncVelocityToPhysics(world, registry);

    // 3. Step physics simulation
    world.update(dt);

    // 4. Sync physics positions back to ECS
    syncPositionsToEcs(world, registry);

    // 5. Sync physics velocities back to Velocity components (if used)
    syncVelocityFromPhysics(world, registry);
}

/// Sync kinematic body positions from ECS to physics.
///
/// Kinematic bodies are controlled by game code, so their positions
/// come from the ECS Position component.
fn syncKinematicBodies(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    var query = registry.query(.{ RigidBody, @TypeOf(registry).Position });
    while (query.next()) |item| {
        const rb = item.get(RigidBody);

        // Only sync kinematic bodies (they're moved by code, not physics)
        if (rb.body_type != .kinematic) continue;

        const entity = entityToU64(item.entity);
        const body_id = world.getBodyId(entity) orelse continue;

        const pos = item.get(@TypeOf(registry).Position);
        const target_pos: [2]f32 = .{
            pos.x / world.pixels_per_meter,
            pos.y / world.pixels_per_meter,
        };

        // Move kinematic body to target position
        world.world.setTransform(body_id, target_pos, world.world.getAngle(body_id));
    }
}

/// Sync Velocity components to physics bodies.
fn syncVelocityToPhysics(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    var query = registry.query(.{ Velocity, RigidBody });
    while (query.next()) |item| {
        const rb = item.get(RigidBody);

        // Only sync dynamic bodies
        if (rb.body_type != .dynamic) continue;

        const entity = entityToU64(item.entity);
        const vel = item.get(Velocity);

        world.setLinearVelocity(entity, vel.linear);
        // Angular velocity sync could be added here
    }
}

/// Sync physics positions back to ECS Position components.
///
/// Dynamic bodies have their positions updated by the physics simulation.
fn syncPositionsToEcs(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    var query = registry.query(.{ RigidBody, @TypeOf(registry).Position });
    while (query.next()) |item| {
        const rb = item.get(RigidBody);

        // Only sync dynamic bodies (physics controls their position)
        if (rb.body_type != .dynamic) continue;

        const entity = entityToU64(item.entity);
        const new_pos = world.getPosition(entity) orelse continue;

        var pos = item.get(@TypeOf(registry).Position);
        pos.x = new_pos[0];
        pos.y = new_pos[1];

        // Mark as dirty for render pipeline
        registry.markDirty(item.entity, @TypeOf(registry).Position);
    }
}

/// Sync physics velocities back to Velocity components.
fn syncVelocityFromPhysics(
    world: *PhysicsWorld,
    registry: anytype,
) void {
    var query = registry.query(.{ Velocity, RigidBody });
    while (query.next()) |item| {
        const rb = item.get(RigidBody);

        // Only sync dynamic bodies
        if (rb.body_type != .dynamic) continue;

        const entity = entityToU64(item.entity);
        const new_vel = world.getLinearVelocity(entity) orelse continue;

        var vel = item.get(Velocity);
        vel.linear = new_vel;
        // Angular velocity sync could be added here
    }
}

// Entity conversion helpers (handle different ECS backends)

fn entityToU64(entity: anytype) u64 {
    const T = @TypeOf(entity);
    if (@hasField(T, "id")) {
        return @intCast(entity.id);
    } else if (@typeInfo(T) == .int) {
        return @intCast(entity);
    } else {
        return @bitCast(entity);
    }
}

fn entityFromU64(id: u64, comptime EntityType: type) EntityType {
    if (@hasField(EntityType, "id")) {
        return .{ .id = @intCast(id) };
    } else if (@typeInfo(EntityType) == .int) {
        return @intCast(id);
    } else {
        return @bitCast(id);
    }
}
