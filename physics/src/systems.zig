//! Physics Systems
//!
//! ECS systems for physics simulation. These integrate the physics world
//! with the ECS registry, handling body creation, synchronization, and cleanup.
//!
//! ECS-native design: Collision state is stored in Touching components,
//! queryable via standard ECS queries (37x faster than central registry per benchmark).
//!
//! Usage:
//! ```zig
//! const physics = @import("labelle-physics");
//!
//! // Create parameterized systems for your Position type
//! const PhysicsSystems = physics.Systems(engine.Position);
//!
//! // In game loop
//! PhysicsSystems.initBodies(&physics_world, registry);
//! PhysicsSystems.update(&physics_world, registry, dt);
//! ```

const std = @import("std");
const PhysicsWorld = @import("world.zig").PhysicsWorld;
const components = @import("components.zig");
const RigidBody = components.RigidBody;
const Collider = components.Collider;
const Velocity = components.Velocity;
const Touching = components.Touching;

/// Create physics systems parameterized by Position type.
///
/// Position must have: x: f32, y: f32, rotation: f32
///
/// Example:
/// ```zig
/// const PhysicsSystems = physics.Systems(engine.Position);
/// PhysicsSystems.initBodies(&physics_world, registry);
/// PhysicsSystems.update(&physics_world, registry, dt);
/// ```
pub fn Systems(comptime Position: type) type {
    // Verify Position has required fields
    comptime {
        if (!@hasField(Position, "x") or !@hasField(Position, "y")) {
            @compileError("Position type must have x and y fields");
        }
        if (!@hasField(Position, "rotation")) {
            @compileError("Position type must have rotation field for physics sync");
        }
    }

    return struct {
        /// Initialize physics bodies for new entities with RigidBody + Position components.
        ///
        /// Call this each frame before the physics update to handle newly created entities.
        /// Entities that already have physics bodies are skipped.
        ///
        /// Example:
        /// ```zig
        /// PhysicsSystems.initBodies(&physics_world, registry);
        /// ```
        pub fn initBodies(
            world: *PhysicsWorld,
            registry: anytype,
        ) void {
            // Query for entities with RigidBody and Position
            var query = registry.query(.{ RigidBody, Position });
            while (query.next()) |item| {
                const entity = entityToU64(item.entity);

                // Skip if already has physics body
                if (world.hasBody(entity)) continue;

                const rb = item.get(RigidBody);
                const pos = item.get(Position);

                world.createBody(entity, rb.*, .{ .x = pos.x, .y = pos.y }) catch |err| {
                    std.log.err("Failed to create physics body for entity {}: {}", .{ entity, err });
                    continue;
                };

                // Add collider if present
                if (registry.tryGet(Collider, item.entity)) |collider| {
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
            const EntityType = @TypeOf(registry).Entity;

            // Iterate over all physics bodies and check if entity still exists
            var entities_to_remove = std.ArrayList(u64).init(world.allocator);
            defer entities_to_remove.deinit();

            var iter = world.body_map.keyIterator();
            while (iter.next()) |entity| {
                // Check if entity exists in registry
                const ecs_entity = entityFromU64(entity.*, EntityType);
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
        /// Steps the physics simulation and syncs results back to ECS.
        /// Includes automatic Touching component updates for collision state.
        /// Uses fixed timestep internally for deterministic simulation.
        ///
        /// Example:
        /// ```zig
        /// PhysicsSystems.update(&physics_world, registry, dt);
        ///
        /// // Query collision state via Touching component
        /// var query = registry.query(.{ Position, Touching });
        /// while (query.next()) |item| {
        ///     const touching = item.get(Touching);
        ///     for (touching.slice()) |other| {
        ///         // Handle collision
        ///     }
        /// }
        /// ```
        pub fn update(
            world: *PhysicsWorld,
            registry: anytype,
            dt: f32,
        ) void {
            // 1. Sync kinematic bodies from ECS -> Physics (position + rotation)
            syncKinematicBodies(world, registry);

            // 2. Sync velocity components to physics (if used)
            syncVelocityToPhysics(world, registry);

            // 3. Step physics simulation
            world.update(dt);

            // 4. Sync physics transforms back to ECS (position + rotation)
            syncTransformsToEcs(world, registry);

            // 5. Sync physics velocities back to Velocity components (if used)
            syncVelocityFromPhysics(world, registry);

            // 6. Update Touching components from collision events
            syncTouchingComponents(world, registry);
        }

        /// Sync kinematic body transforms from ECS to physics.
        ///
        /// Kinematic bodies are controlled by game code, so their positions
        /// and rotations come from the ECS Position component.
        fn syncKinematicBodies(
            world: *PhysicsWorld,
            registry: anytype,
        ) void {
            var query = registry.query(.{ RigidBody, Position });
            while (query.next()) |item| {
                const rb = item.get(RigidBody);

                // Only sync kinematic bodies (they're moved by code, not physics)
                if (rb.body_type != .kinematic) continue;

                const entity = entityToU64(item.entity);
                const body_id = world.getBodyId(entity) orelse continue;

                const pos = item.get(Position);
                const target_pos: [2]f32 = .{
                    pos.x / world.pixels_per_meter,
                    pos.y / world.pixels_per_meter,
                };

                // Move kinematic body to target position and rotation
                world.world.setTransform(body_id, target_pos, pos.rotation);
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

        /// Sync physics transforms (position + rotation) back to ECS Position components.
        ///
        /// Dynamic bodies have their transforms updated by the physics simulation.
        fn syncTransformsToEcs(
            world: *PhysicsWorld,
            registry: anytype,
        ) void {
            var query = registry.query(.{ RigidBody, Position });
            while (query.next()) |item| {
                const rb = item.get(RigidBody);

                // Only sync dynamic bodies (physics controls their position)
                if (rb.body_type != .dynamic) continue;

                const entity = entityToU64(item.entity);
                const new_pos = world.getPosition(entity) orelse continue;
                const new_angle = world.getAngle(entity) orelse continue;

                var pos = item.get(Position);
                pos.x = new_pos[0];
                pos.y = new_pos[1];
                pos.rotation = new_angle;
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

        /// Sync Touching components from collision events.
        ///
        /// Updates Touching components based on begin/end collision events.
        /// Entities with RigidBody automatically get Touching component managed.
        fn syncTouchingComponents(
            world: *PhysicsWorld,
            registry: anytype,
        ) void {
            const EntityType = @TypeOf(registry).Entity;

            // Process collision begin events - add to Touching
            for (world.getCollisionBeginEvents()) |event| {
                // Update entity A's Touching to include B
                const entity_a = entityFromU64(event.entity_a, EntityType);
                if (registry.tryGetPtr(Touching, entity_a)) |touching_a| {
                    touching_a.add(event.entity_b);
                } else if (registry.isValid(entity_a)) {
                    // Auto-add Touching component if entity has RigidBody
                    if (registry.tryGet(RigidBody, entity_a)) |_| {
                        var touching = Touching{};
                        touching.add(event.entity_b);
                        registry.add(entity_a, touching);
                    }
                }

                // Update entity B's Touching to include A
                const entity_b = entityFromU64(event.entity_b, EntityType);
                if (registry.tryGetPtr(Touching, entity_b)) |touching_b| {
                    touching_b.add(event.entity_a);
                } else if (registry.isValid(entity_b)) {
                    if (registry.tryGet(RigidBody, entity_b)) |_| {
                        var touching = Touching{};
                        touching.add(event.entity_a);
                        registry.add(entity_b, touching);
                    }
                }
            }

            // Process collision end events - remove from Touching
            for (world.getCollisionEndEvents()) |event| {
                const entity_a = entityFromU64(event.entity_a, EntityType);
                if (registry.tryGetPtr(Touching, entity_a)) |touching_a| {
                    touching_a.remove(event.entity_b);
                }

                const entity_b = entityFromU64(event.entity_b, EntityType);
                if (registry.tryGetPtr(Touching, entity_b)) |touching_b| {
                    touching_b.remove(event.entity_a);
                }
            }

            // Process sensor events similarly
            for (world.getSensorEnterEvents()) |event| {
                const sensor_entity = entityFromU64(event.sensor_entity, EntityType);
                if (registry.tryGetPtr(Touching, sensor_entity)) |touching| {
                    touching.add(event.other_entity);
                } else if (registry.isValid(sensor_entity)) {
                    if (registry.tryGet(RigidBody, sensor_entity)) |_| {
                        var touching = Touching{};
                        touching.add(event.other_entity);
                        registry.add(sensor_entity, touching);
                    }
                }
            }

            for (world.getSensorExitEvents()) |event| {
                const sensor_entity = entityFromU64(event.sensor_entity, EntityType);
                if (registry.tryGetPtr(Touching, sensor_entity)) |touching| {
                    touching.remove(event.other_entity);
                }
            }
        }
    };
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
