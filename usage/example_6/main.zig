// Example 6: RenderPipeline with RetainedEngine
//
// Demonstrates the new Position-as-component architecture:
// - ECS owns Position (source of truth)
// - RenderPipeline syncs dirty positions to RetainedEngine
// - Sprite, Shape, Text components for visuals

const std = @import("std");
const engine = @import("labelle-engine");
const labelle = @import("labelle");
const ecs = @import("ecs");

// Import render pipeline types
const Position = engine.Position;
const Sprite = engine.Sprite;
const Shape = engine.Shape;
const RenderPipeline = engine.RenderPipeline;
const RetainedEngine = engine.RetainedEngine;
const Color = engine.Color;

// ECS types
const Registry = ecs.Registry;
const Entity = ecs.Entity;

// Custom component for velocity
const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize RetainedEngine (new API)
    var ve = try RetainedEngine.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Example 6: RenderPipeline",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    defer ve.deinit();

    // Initialize ECS registry
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Initialize RenderPipeline
    var pipeline = RenderPipeline.init(allocator, &ve);
    defer pipeline.deinit();

    // Create entities with Position + visual components
    // Entity 1: Moving circle
    const circle_entity = registry.create();
    registry.add(circle_entity, Position{ .x = 200, .y = 300 });
    registry.add(circle_entity, Velocity{ .x = 100, .y = 50 });
    var circle_shape = Shape.circle(40);
    circle_shape.color = Color.red;
    circle_shape.z_index = 100;
    registry.add(circle_entity, circle_shape);
    try pipeline.trackEntity(circle_entity, .shape);

    // Entity 2: Static rectangle
    const rect_entity = registry.create();
    registry.add(rect_entity, Position{ .x = 500, .y = 200 });
    var rect_shape = Shape.rectangle(100, 60);
    rect_shape.color = Color.green;
    rect_shape.z_index = 50;
    registry.add(rect_entity, rect_shape);
    try pipeline.trackEntity(rect_entity, .shape);

    // Entity 3: Another circle (bouncing)
    const bounce_entity = registry.create();
    registry.add(bounce_entity, Position{ .x = 600, .y = 400 });
    registry.add(bounce_entity, Velocity{ .x = -80, .y = 120 });
    var bounce_shape = Shape.circle(25);
    bounce_shape.color = Color.blue;
    bounce_shape.z_index = 75;
    registry.add(bounce_entity, bounce_shape);
    try pipeline.trackEntity(bounce_entity, .shape);

    std.debug.print("Example 6: RenderPipeline started\n", .{});
    std.debug.print("  Tracked entities: {d}\n", .{pipeline.count()});

    var frame_count: u32 = 0;
    const max_frames: u32 = if (ci_test) 120 else 99999;

    // Game loop
    while (ve.isRunning() and frame_count < max_frames) {
        const dt = ve.getDeltaTime();
        frame_count += 1;

        // Update physics (move entities with velocity)
        updatePhysics(&registry, &pipeline, dt);

        // Sync ECS state to RetainedEngine
        pipeline.sync(&registry);

        // Render
        ve.beginFrame();
        ve.render();
        ve.endFrame();
    }

    std.debug.print("Example 6 completed. Frames: {d}\n", .{frame_count});

    // CI assertion
    if (ci_test) {
        std.debug.assert(frame_count >= 60);
        std.debug.assert(pipeline.count() == 3);
    }
}

fn updatePhysics(registry: *Registry, pipeline: *RenderPipeline, dt: f32) void {
    // Query entities with Position and Velocity
    var view = registry.view(.{ Position, Velocity }, .{});
    var iter = view.entityIterator();

    while (iter.next()) |entity| {
        var pos = view.get(Position, entity);
        var vel = view.get(Velocity, entity);

        // Update position
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;

        // Bounce off walls
        if (pos.x < 50 or pos.x > 750) {
            vel.x = -vel.x;
            pos.x = @max(50, @min(750, pos.x));
        }
        if (pos.y < 50 or pos.y > 550) {
            vel.y = -vel.y;
            pos.y = @max(50, @min(550, pos.y));
        }

        // Mark position as dirty so RenderPipeline syncs it
        pipeline.markPositionDirty(entity);
    }
}

test "example_6 compiles" {
    _ = Position;
    _ = Sprite;
    _ = Shape;
    _ = RenderPipeline;
    _ = Velocity;
}
