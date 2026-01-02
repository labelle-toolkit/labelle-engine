// Physics Demo Script
//
// Demonstrates ECS-native physics using physics.Systems.
// Left click: spawn box, Right click: spawn circle, R: reset
//
// Key pattern: Use PhysicsSystems.initBodies() and PhysicsSystems.update()
// for automatic ECS integration. Query collisions via Touching component.

const std = @import("std");
const engine = @import("labelle-engine");
const physics = @import("labelle-physics");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;
const Position = engine.Position;
const Shape = engine.Shape;

// Physics components
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;
const Touching = physics.Touching;
const PhysicsWorld = physics.PhysicsWorld;

// Create parameterized physics systems for our Position type
const PhysicsSystems = physics.Systems(Position);

// Script state
var physics_world: ?PhysicsWorld = null;
var spawn_timer: f32 = 0;
var script_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

const spawn_cooldown: f32 = 0.1;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    script_allocator = game.allocator;

    // Initialize physics world with gravity (pixels/sec^2)
    physics_world = PhysicsWorld.init(script_allocator, .{ 0, 980 }) catch |err| {
        std.log.err("Failed to init physics: {}", .{err});
        return;
    };

    initialized = true;
    spawn_timer = 0;

    // Initialize physics bodies for all entities with RigidBody + Position
    // This is called once on scene load to set up existing entities
    PhysicsSystems.initBodies(&(physics_world.?), game.getRegistry());

    std.log.info("Physics demo initialized", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized or physics_world == null) return;

    const registry = game.getRegistry();
    const input = game.getInput();

    var pw = &(physics_world.?);

    // Initialize any new entities (spawned this frame)
    PhysicsSystems.initBodies(pw, registry);

    // Main physics update - handles:
    // 1. Syncing kinematic transforms ECS -> physics
    // 2. Syncing Velocity components to physics
    // 3. Stepping the physics simulation
    // 4. Syncing physics transforms back to ECS (Position.x, Position.y, Position.rotation)
    // 5. Syncing physics velocities back to Velocity components
    // 6. Updating Touching components from collision events
    PhysicsSystems.update(pw, registry, dt);

    // Example: Query collision state via Touching component (37x faster than events)
    // var query = registry.query(.{ Position, Touching });
    // while (query.next()) |item| {
    //     const touching = item.get(Touching);
    //     if (!touching.isEmpty()) {
    //         // Entity is touching something
    //         for (touching.slice()) |other_id| {
    //             // Handle collision with other_id
    //         }
    //     }
    // }

    // Spawn timer
    spawn_timer -= dt;

    // Spawn box on left click
    if (input.isMouseButtonDown(.left) and spawn_timer <= 0) {
        spawnBox(game, pw);
        spawn_timer = spawn_cooldown;
    }

    // Spawn circle on right click
    if (input.isMouseButtonDown(.right) and spawn_timer <= 0) {
        spawnCircle(game, pw);
        spawn_timer = spawn_cooldown;
    }

    // Reset scene on R key
    if (input.isKeyPressed(.r)) {
        game.queueSceneChange("main");
    }
}

fn spawnBox(game: *Game, pw: *PhysicsWorld) void {
    _ = pw; // Physics body created by systems.initBodies next frame

    const mouse_pos = game.getInput().getMousePosition();

    // Random color and size
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const size: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 20, 50));

    const entity = game.createEntity();
    const registry = game.getRegistry();

    // Add Position
    game.addPosition(entity, .{ .x = mouse_pos.x, .y = mouse_pos.y });

    // Add Shape for rendering
    var shape = engine.Shape.rectangle(size, size);
    shape.color = .{ .r = r, .g = g, .b = b, .a = 255 };
    game.addShape(entity, shape) catch return;

    // Add physics components - body will be created automatically by systems.initBodies
    registry.set(entity, RigidBody{ .body_type = .dynamic });
    registry.set(entity, Collider{
        .shape = .{ .box = .{ .width = size, .height = size } },
        .restitution = 0.4,
    });
}

fn spawnCircle(game: *Game, pw: *PhysicsWorld) void {
    _ = pw; // Physics body created by systems.initBodies next frame

    const mouse_pos = game.getInput().getMousePosition();

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const radius: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 10, 30));

    const entity = game.createEntity();
    const registry = game.getRegistry();

    game.addPosition(entity, .{ .x = mouse_pos.x, .y = mouse_pos.y });

    var shape = engine.Shape.circle(radius);
    shape.color = .{ .r = r, .g = g, .b = b, .a = 255 };
    game.addShape(entity, shape) catch return;

    // Add physics components - body will be created automatically by systems.initBodies
    registry.set(entity, RigidBody{ .body_type = .dynamic });
    registry.set(entity, Collider{
        .shape = .{ .circle = .{ .radius = radius } },
        .restitution = 0.7,
    });
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;

    if (physics_world) |*pw| {
        pw.deinit();
        physics_world = null;
    }

    spawn_timer = 0;
    initialized = false;
}
