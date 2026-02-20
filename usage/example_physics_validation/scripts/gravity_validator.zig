// Gravity Validator Script
//
// Validates that entities with GravityBody component fall under gravity.
// After VALIDATION_SECONDS, checks that dynamic bodies have moved from
// their initial positions.

const std = @import("std");
const engine = @import("labelle-engine");
const physics = @import("labelle-physics");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.Position;
const Shape = engine.Shape;

// Import component from local components folder
const GravityBody = @import("../components/gravity_body.zig").GravityBody;
const BodyType = @import("../components/gravity_body.zig").BodyType;

const RigidBody = physics.RigidBody;
const Collider = physics.Collider;
const PhysicsWorld = physics.PhysicsWorld;

/// Seconds to wait before validating positions
const VALIDATION_SECONDS: f32 = 2.0;

/// Minimum distance an entity must have moved to pass validation
const MIN_MOVEMENT: f32 = 50.0;

/// Tracked entity data
const TrackedEntity = struct {
    entity: Entity,
    initial_y: f32,
    is_dynamic: bool,
};

/// Script state (module-level static variables)
var physics_world: ?PhysicsWorld = null;
var tracked_entities: std.ArrayList(TrackedEntity) = .{};
var elapsed_time: f32 = 0;
var validation_done: bool = false;
var script_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    script_allocator = game.allocator;
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Initialize physics world with gravity (positive Y = down in screen coords)
    physics_world = PhysicsWorld.init(script_allocator, .{ 0, 980 }) catch |err| {
        std.log.err("Failed to init physics: {}", .{err});
        return;
    };

    tracked_entities = .{};
    initialized = true;

    std.log.info("Gravity validator: scanning {} entities", .{scene.entities.items.len});

    // Find all entities with GravityBody and Position components
    for (scene.entities.items) |entity_instance| {
        const entity = entity_instance.entity;

        // Check for required components
        const pos = registry.getComponent(entity, Position) orelse continue;
        const shape = registry.getComponent(entity, Shape) orelse continue;
        const gravity_body = registry.getComponent(entity, GravityBody) orelse continue;

        const is_dynamic = gravity_body.body_type == .dynamic;

        std.log.info("Found entity with GravityBody: pos=({d:.1}, {d:.1}), dynamic={}", .{
            pos.x, pos.y, is_dynamic,
        });

        // Track initial position for validation
        tracked_entities.append(script_allocator, .{
            .entity = entity,
            .initial_y = pos.y,
            .is_dynamic = is_dynamic,
        }) catch continue;

        // Create physics body
        const body_type: physics.BodyType = switch (gravity_body.body_type) {
            .dynamic => .dynamic,
            .static => .static,
            .kinematic => .kinematic,
        };

        var pw = &(physics_world.?);
        pw.createBody(engine.entityToU64(entity), RigidBody{
            .body_type = body_type,
        }, .{ .x = pos.x, .y = pos.y }) catch |err| {
            std.log.err("Failed to create body for entity: {}", .{err});
            continue;
        };

        // Add collider based on shape type
        const collider: Collider = switch (shape.shape) {
            .rectangle => |rect| .{
                .shape = .{ .box = .{ .width = rect.width, .height = rect.height } },
                .restitution = gravity_body.restitution,
                .friction = gravity_body.friction,
            },
            .circle => |circ| .{
                .shape = .{ .circle = .{ .radius = circ.radius } },
                .restitution = gravity_body.restitution,
                .friction = gravity_body.friction,
            },
            else => continue,
        };

        pw.addCollider(engine.entityToU64(entity), collider) catch |err| {
            std.log.err("Failed to add collider: {}", .{err});
        };

        // Mark entity as tracked by pipeline for rendering
        pipeline.markPositionDirty(entity);
    }

    std.log.info("Gravity validator initialized. Tracking {} entities. Validation in {d:.1}s", .{
        tracked_entities.items.len,
        VALIDATION_SECONDS,
    });
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized or physics_world == null) return;

    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    var pw = &(physics_world.?);

    // Update physics simulation
    pw.update(dt);

    // Sync physics positions to ECS
    for (pw.entities()) |entity_id| {
        if (pw.getPosition(entity_id)) |phys_pos| {
            const entity = engine.entityFromU64(entity_id);
            if (registry.getComponent(entity, Position)) |pos| {
                pos.x = phys_pos[0];
                pos.y = phys_pos[1];
                pipeline.markPositionDirty(entity);
            }
        }
    }

    // Track elapsed time
    elapsed_time += dt;

    // Perform validation after VALIDATION_SECONDS
    if (!validation_done and elapsed_time >= VALIDATION_SECONDS) {
        validation_done = true;
        performValidation(game);
    }
}

fn performValidation(game: *Game) void {
    const registry = game.getRegistry();

    std.log.info("=== GRAVITY VALIDATION RESULTS ===", .{});
    std.log.info("Elapsed time: {d:.2}s", .{elapsed_time});

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    for (tracked_entities.items) |tracked| {
        // Skip static bodies (they shouldn't move)
        if (!tracked.is_dynamic) {
            skipped += 1;
            continue;
        }

        // Get current position
        const current_pos = registry.getComponent(tracked.entity, Position) orelse {
            std.log.warn("Entity no longer has position", .{});
            failed += 1;
            continue;
        };

        const movement = current_pos.y - tracked.initial_y;
        const moved_enough = movement >= MIN_MOVEMENT;

        if (moved_enough) {
            passed += 1;
            std.log.info("PASS: Entity moved {d:.1} pixels (initial_y={d:.1}, current_y={d:.1})", .{
                movement,
                tracked.initial_y,
                current_pos.y,
            });
        } else {
            failed += 1;
            std.log.err("FAIL: Entity only moved {d:.1} pixels (expected >= {d:.1})", .{
                movement,
                MIN_MOVEMENT,
            });
        }
    }

    std.log.info("=== SUMMARY ===", .{});
    std.log.info("Passed: {}, Failed: {}, Skipped (static): {}", .{ passed, failed, skipped });

    if (failed == 0 and passed > 0) {
        std.log.info("SUCCESS: All dynamic entities are falling correctly!", .{});
    } else if (failed > 0) {
        std.log.err("FAILURE: Some entities did not move as expected", .{});
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;

    if (physics_world) |*pw| {
        pw.deinit();
        physics_world = null;
    }

    tracked_entities.deinit(script_allocator);
    tracked_entities = .{};

    elapsed_time = 0;
    validation_done = false;
    initialized = false;
}
