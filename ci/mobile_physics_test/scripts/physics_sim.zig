// Physics Simulation Script
// Updates physics world and syncs positions back to ECS
// Uses physics.Systems for automatic ECS integration

const std = @import("std");
const engine = @import("labelle-engine");
const physics = @import("labelle-physics");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

// Physics components
const RigidBody = physics.RigidBody;
const PhysicsWorld = physics.PhysicsWorld;

// Create parameterized physics systems for our Position type
const PhysicsSystems = physics.Systems(Position);

// Script state
var physics_world: ?PhysicsWorld = null;
var initialized: bool = false;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.log.info("Initializing physics world...", .{});

    // Initialize physics world with gravity (pixels/sec^2)
    physics_world = PhysicsWorld.init(game.allocator, .{ 0, 980 }) catch |err| {
        std.log.err("Failed to init physics: {}", .{err});
        return;
    };

    initialized = true;

    // Initialize physics bodies for all entities with RigidBody + Position
    PhysicsSystems.initBodies(&(physics_world.?), game.getRegistry());

    std.log.info("Physics world initialized", .{});
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
    // 3. Syncing physics transforms back to ECS
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
    std.log.info("Physics world destroyed", .{});
}
