// Physics Demo Script
//
// Initializes physics world and syncs positions.
// Left click: spawn box, Right click: spawn circle, R: reset

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
const BodyType = physics.BodyType;
const PhysicsWorld = physics.PhysicsWorld;

// Script state
var physics_world: ?PhysicsWorld = null;
var spawn_timer: f32 = 0;
var script_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

const spawn_cooldown: f32 = 0.1;

pub fn init(game: *Game, scene: *Scene) void {
    script_allocator = game.allocator;
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Initialize physics world with gravity
    physics_world = PhysicsWorld.init(script_allocator, .{ 0, 980 }) catch |err| {
        std.log.err("Failed to init physics: {}", .{err});
        return;
    };

    initialized = true;
    spawn_timer = 0;

    std.log.info("Physics demo: scanning {} entities", .{scene.entities.items.len});

    // Find all entities with RigidBody and Position components
    for (scene.entities.items) |entity_instance| {
        const entity = entity_instance.entity;

        const pos = registry.tryGet(Position, entity) orelse continue;
        const rigid_body = registry.tryGet(RigidBody, entity) orelse continue;
        const collider = registry.tryGet(Collider, entity) orelse continue;

        std.log.info("Found entity with RigidBody+Collider: pos=({d:.1}, {d:.1}), type={s}", .{
            pos.x,
            pos.y,
            @tagName(rigid_body.body_type),
        });

        var pw = &(physics_world.?);

        // Create physics body
        pw.createBody(engine.entityToU64(entity), rigid_body.*, .{ .x = pos.x, .y = pos.y }) catch |err| {
            std.log.err("Failed to create body for entity: {}", .{err});
            continue;
        };

        // Add collider
        pw.addCollider(engine.entityToU64(entity), collider.*) catch |err| {
            std.log.err("Failed to add collider: {}", .{err});
        };

        pipeline.markPositionDirty(entity);
    }

    std.log.info("Physics demo initialized with {} entities", .{scene.entities.items.len});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    if (!initialized or physics_world == null) return;

    const registry = game.getRegistry();
    const pipeline = game.getPipeline();
    const input = game.getInput();

    var pw = &(physics_world.?);

    // Update physics simulation
    pw.update(dt);

    // Sync physics positions to ECS
    for (pw.entities()) |entity_id| {
        if (pw.getPosition(entity_id)) |phys_pos| {
            const entity = engine.entityFromU64(entity_id);
            if (registry.tryGet(Position, entity)) |pos| {
                pos.x = phys_pos[0];
                pos.y = phys_pos[1];
                pipeline.markPositionDirty(entity);
            }
        }
    }

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
    const mouse_pos = game.getInput().getMousePosition();

    // Random color and size
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const size: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 20, 50));

    const entity = game.createEntity();

    // Add Position
    game.addPosition(entity, .{ .x = mouse_pos.x, .y = mouse_pos.y });

    // Add Shape for rendering
    var shape = engine.Shape.rectangle(size, size);
    shape.color = .{ .r = r, .g = g, .b = b, .a = 255 };
    game.addShape(entity, shape) catch return;

    // Add to physics world
    pw.createBody(engine.entityToU64(entity), RigidBody{
        .body_type = .dynamic,
    }, .{ .x = mouse_pos.x, .y = mouse_pos.y }) catch return;

    pw.addCollider(engine.entityToU64(entity), Collider{
        .shape = .{ .box = .{ .width = size, .height = size } },
        .restitution = 0.4,
    }) catch return;
}

fn spawnCircle(game: *Game, pw: *PhysicsWorld) void {
    const mouse_pos = game.getInput().getMousePosition();

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const radius: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 10, 30));

    const entity = game.createEntity();

    game.addPosition(entity, .{ .x = mouse_pos.x, .y = mouse_pos.y });

    var shape = engine.Shape.circle(radius);
    shape.color = .{ .r = r, .g = g, .b = b, .a = 255 };
    game.addShape(entity, shape) catch return;

    pw.createBody(engine.entityToU64(entity), RigidBody{
        .body_type = .dynamic,
    }, .{ .x = mouse_pos.x, .y = mouse_pos.y }) catch return;

    pw.addCollider(engine.entityToU64(entity), Collider{
        .shape = .{ .circle = .{ .radius = radius } },
        .restitution = 0.7,
    }) catch return;
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
