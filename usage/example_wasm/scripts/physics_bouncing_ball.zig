// Physics Bouncing Ball Script
//
// Uses Box2D physics for realistic ball bouncing.
// Demonstrates ECS-native physics using PhysicsSystems.

const std = @import("std");
const engine = @import("labelle-engine");
const physics = engine.physics;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

// Physics components and systems
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;
const PhysicsWorld = physics.PhysicsWorld;
const PhysicsSystems = physics.Systems(Position);

// Script state
var physics_world: ?PhysicsWorld = null;
var script_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    script_allocator = game.allocator;

    // Initialize physics world with gravity (pixels/sec^2)
    // Positive Y is down in screen coordinates
    physics_world = PhysicsWorld.init(script_allocator, .{ 0, 500 }) catch |err| {
        std.log.err("Failed to init physics: {}", .{err});
        return;
    };

    initialized = true;

    // Initialize physics bodies for all entities with RigidBody + Position
    PhysicsSystems.initBodies(&(physics_world.?), game.getRegistry());

    std.log.info("Physics bouncing ball initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized or physics_world == null) return;

    const registry = game.getRegistry();
    const pw = &(physics_world.?);

    // Initialize any new entities (spawned this frame)
    PhysicsSystems.initBodies(pw, registry);

    // Main physics update - handles:
    // 1. Syncing kinematic transforms ECS -> physics
    // 2. Stepping the physics simulation
    // 3. Syncing physics transforms back to ECS (Position.x, Position.y, Position.rotation)
    // 4. Updating Touching components from collision events
    PhysicsSystems.update(pw, registry, dt);

    // Mark all dynamic body positions as dirty for render pipeline
    var pipeline = game.getPipeline();
    var body_query = registry.query(.{RigidBody});
    while (body_query.next()) |item| {
        if (item.get(RigidBody).body_type == .dynamic) {
            pipeline.markPositionDirty(item.entity);
        }
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;

    if (physics_world) |*pw| {
        pw.deinit();
        physics_world = null;
    }

    initialized = false;
}
