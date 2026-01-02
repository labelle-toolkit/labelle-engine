// Physics Demo Script
//
// Click to spawn new physics boxes at mouse position.
// Press R to reset the scene.

const std = @import("std");
const engine = @import("labelle-engine");

var spawn_timer: f32 = 0;
const spawn_cooldown: f32 = 0.1; // seconds between spawns

pub fn update(game: *engine.Game, scene: *engine.Scene, dt: f32) void {
    _ = scene;

    spawn_timer -= dt;

    const input = game.getInput();

    // Spawn box on left click
    if (input.isMouseButtonDown(.left) and spawn_timer <= 0) {
        spawnBox(game);
        spawn_timer = spawn_cooldown;
    }

    // Spawn circle on right click
    if (input.isMouseButtonDown(.right) and spawn_timer <= 0) {
        spawnCircle(game);
        spawn_timer = spawn_cooldown;
    }

    // Reset scene on R key
    if (input.isKeyPressed(.r)) {
        game.loadScene("main") catch {};
    }

    // Log collision events (for debugging)
    if (game.getPhysicsWorld()) |physics_world| {
        for (physics_world.getCollisionBeginEvents()) |event| {
            _ = event;
            // Uncomment to see collision debug:
            // std.log.debug("Collision: {} <-> {}", .{ event.entity_a, event.entity_b });
        }
    }
}

fn spawnBox(game: *engine.Game) void {
    const mouse_pos = game.getInput().getMousePosition();

    // Random color
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));

    // Random size
    const size: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 20, 50));

    const entity = game.createEntity() catch return;

    // Add Position
    game.addComponent(entity, engine.Position{ .x = mouse_pos.x, .y = mouse_pos.y }) catch return;

    // Add Shape for rendering
    game.addComponent(entity, engine.Shape{
        .type = .rectangle,
        .width = size,
        .height = size,
        .color = .{ .r = r, .g = g, .b = b },
    }) catch return;

    // Add physics components
    game.addComponent(entity, engine.physics.RigidBody{
        .body_type = .dynamic,
    }) catch return;

    game.addComponent(entity, engine.physics.Collider{
        .shape = .{ .box = .{ .width = size, .height = size } },
        .restitution = 0.4,
    }) catch return;
}

fn spawnCircle(game: *engine.Game) void {
    const mouse_pos = game.getInput().getMousePosition();

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const r: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const g: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));
    const b: u8 = @intCast(rng.random().intRangeAtMost(u8, 100, 255));

    const radius: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 10, 30));

    const entity = game.createEntity() catch return;

    game.addComponent(entity, engine.Position{ .x = mouse_pos.x, .y = mouse_pos.y }) catch return;

    game.addComponent(entity, engine.Shape{
        .type = .circle,
        .radius = radius,
        .color = .{ .r = r, .g = g, .b = b },
    }) catch return;

    game.addComponent(entity, engine.physics.RigidBody{
        .body_type = .dynamic,
    }) catch return;

    game.addComponent(entity, engine.physics.Collider{
        .shape = .{ .circle = .{ .radius = radius } },
        .restitution = 0.7,
    }) catch return;
}
