// Physics Demo - main.zig
//
// Demonstrates physics integration with labelle-engine.
// Left click: spawn box, Right click: spawn circle, R: reset

const std = @import("std");
const engine = @import("labelle-engine");
const physics = @import("labelle-physics");

// Physics components
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize game
    var game = try engine.Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "labelle-engine: Physics Demo",
        },
    });
    game.fixPointers();
    defer game.deinit();

    // Initialize physics world
    var physics_world = try physics.PhysicsWorld.init(allocator, .{ 0, 980 });
    defer physics_world.deinit();

    // Create ground
    {
        const ground = game.createEntity();
        game.setPositionXY(ground, 400, 550);
        var ground_shape = engine.Shape.rectangle(700, 20);
        ground_shape.color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
        try game.addShape(ground, ground_shape);
        try physics_world.createBody(engine.entityToU64(ground), RigidBody{ .body_type = .static }, .{ .x = 400, .y = 550 });
        try physics_world.addCollider(engine.entityToU64(ground), Collider{
            .shape = .{ .box = .{ .width = 700, .height = 20 } },
        });
    }

    // Create walls
    {
        const left_wall = game.createEntity();
        game.setPositionXY(left_wall, 50, 300);
        var left_wall_shape = engine.Shape.rectangle(20, 500);
        left_wall_shape.color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
        try game.addShape(left_wall, left_wall_shape);
        try physics_world.createBody(engine.entityToU64(left_wall), RigidBody{ .body_type = .static }, .{ .x = 50, .y = 300 });
        try physics_world.addCollider(engine.entityToU64(left_wall), Collider{
            .shape = .{ .box = .{ .width = 20, .height = 500 } },
        });
    }
    {
        const right_wall = game.createEntity();
        game.setPositionXY(right_wall, 750, 300);
        var right_wall_shape = engine.Shape.rectangle(20, 500);
        right_wall_shape.color = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
        try game.addShape(right_wall, right_wall_shape);
        try physics_world.createBody(engine.entityToU64(right_wall), RigidBody{ .body_type = .static }, .{ .x = 750, .y = 300 });
        try physics_world.addCollider(engine.entityToU64(right_wall), Collider{
            .shape = .{ .box = .{ .width = 20, .height = 500 } },
        });
    }

    // Create some initial dynamic boxes
    try spawnBox(&game, &physics_world, 200, 100, 40, .{ .r = 200, .g = 50, .b = 50, .a = 255 });
    try spawnBox(&game, &physics_world, 400, 50, 50, .{ .r = 50, .g = 200, .b = 50, .a = 255 });
    try spawnBox(&game, &physics_world, 600, 150, 35, .{ .r = 50, .g = 50, .b = 200, .a = 255 });
    try spawnCircle(&game, &physics_world, 300, 200, 25, .{ .r = 200, .g = 200, .b = 50, .a = 255 });
    try spawnCircle(&game, &physics_world, 500, 80, 20, .{ .r = 200, .g = 100, .b = 200, .a = 255 });

    var spawn_timer: f32 = 0;
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));

    // Main loop
    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        spawn_timer -= dt;

        // Input handling
        const input = game.getInput();

        // Spawn on click
        if (input.isMouseButtonDown(.left) and spawn_timer <= 0) {
            const pos = input.getMousePosition();
            const size: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 20, 50));
            const color = randomColor(&rng);
            try spawnBox(&game, &physics_world, pos.x, pos.y, size, color);
            spawn_timer = 0.1;
        }
        if (input.isMouseButtonDown(.right) and spawn_timer <= 0) {
            const pos = input.getMousePosition();
            const radius: f32 = @floatFromInt(rng.random().intRangeAtMost(u32, 10, 30));
            const color = randomColor(&rng);
            try spawnCircle(&game, &physics_world, pos.x, pos.y, radius, color);
            spawn_timer = 0.1;
        }

        // Update physics
        physics_world.update(dt);

        // Sync physics positions to ECS
        for (physics_world.entities()) |entity_id| {
            if (physics_world.getPosition(entity_id)) |pos| {
                const entity = engine.entityFromU64(entity_id);
                game.setPositionXY(entity, pos[0], pos[1]);
            }
        }

        // Render
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        re.endFrame();
    }
}

fn spawnBox(
    game: *engine.Game,
    physics_world: *physics.PhysicsWorld,
    x: f32,
    y: f32,
    size: f32,
    color: engine.Color,
) !void {
    const entity = game.createEntity();
    game.setPositionXY(entity, x, y);
    var shape = engine.Shape.rectangle(size, size);
    shape.color = color;
    try game.addShape(entity, shape);
    try physics_world.createBody(engine.entityToU64(entity), RigidBody{ .body_type = .dynamic }, .{ .x = x, .y = y });
    try physics_world.addCollider(engine.entityToU64(entity), Collider{
        .shape = .{ .box = .{ .width = size, .height = size } },
        .restitution = 0.4,
    });
}

fn spawnCircle(
    game: *engine.Game,
    physics_world: *physics.PhysicsWorld,
    x: f32,
    y: f32,
    radius: f32,
    color: engine.Color,
) !void {
    const entity = game.createEntity();
    game.setPositionXY(entity, x, y);
    var shape = engine.Shape.circle(radius);
    shape.color = color;
    try game.addShape(entity, shape);
    try physics_world.createBody(engine.entityToU64(entity), RigidBody{ .body_type = .dynamic }, .{ .x = x, .y = y });
    try physics_world.addCollider(engine.entityToU64(entity), Collider{
        .shape = .{ .circle = .{ .radius = radius } },
        .restitution = 0.7,
    });
}

fn randomColor(rng: *std.Random.DefaultPrng) engine.Color {
    return .{
        .r = @intCast(rng.random().intRangeAtMost(u8, 100, 255)),
        .g = @intCast(rng.random().intRangeAtMost(u8, 100, 255)),
        .b = @intCast(rng.random().intRangeAtMost(u8, 100, 255)),
        .a = 255,
    };
}
