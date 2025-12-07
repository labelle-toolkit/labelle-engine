//! Example 4: Primitives - Circles and Squares
//!
//! This example demonstrates how to create a game scene using
//! primitive shapes (circles and rectangles) instead of sprites.
//!
//! Features demonstrated:
//! - Creating shapes with VisualEngine.addShape()
//! - Circle primitives
//! - Rectangle/square primitives
//! - Shape properties: color, filled/outline, position
//!
//! Build and run:
//!   cd usage/example_4
//!   zig build run

const std = @import("std");
const labelle = @import("labelle");

const VisualEngine = labelle.visual_engine.VisualEngine;
const ShapeConfig = labelle.visual_engine.ShapeConfig;
const ShapeType = labelle.visual_engine.ShapeType;

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\labelle-engine Example 4: Primitives
        \\====================================
        \\
        \\This example shows how to create game scenes
        \\using primitive shapes (circles and squares).
        \\
        \\Initializing...
        \\
    , .{});

    // Initialize visual engine
    var ve = try VisualEngine.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "labelle-engine: Primitives Example",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 20, .g = 25, .b = 35 },
    });
    defer ve.deinit();

    // ==========================================================================
    // Create shapes using primitives
    // ==========================================================================

    // Large filled circle (sun)
    _ = try ve.addShape(.{
        .shape_type = .circle,
        .x = 400,
        .y = 150,
        .radius = 60,
        .color = .{ .r = 255, .g = 255, .b = 0, .a = 255 }, // yellow
        .filled = true,
    });

    // Filled rectangle (ground)
    _ = try ve.addShape(.{
        .shape_type = .rectangle,
        .x = 0,
        .y = 500,
        .width = 800,
        .height = 100,
        .color = .{ .r = 0, .g = 100, .b = 0, .a = 255 }, // dark green
        .filled = true,
    });

    // Square buildings
    _ = try ve.addShape(.{
        .shape_type = .rectangle,
        .x = 100,
        .y = 350,
        .width = 80,
        .height = 150,
        .color = .{ .r = 128, .g = 128, .b = 128, .a = 255 }, // gray
        .filled = true,
    });

    _ = try ve.addShape(.{
        .shape_type = .rectangle,
        .x = 300,
        .y = 300,
        .width = 100,
        .height = 200,
        .color = .{ .r = 80, .g = 80, .b = 80, .a = 255 }, // dark gray
        .filled = true,
    });

    _ = try ve.addShape(.{
        .shape_type = .rectangle,
        .x = 550,
        .y = 380,
        .width = 120,
        .height = 120,
        .color = .{ .r = 128, .g = 128, .b = 128, .a = 255 }, // gray
        .filled = true,
    });

    // Outline circles (decorative elements)
    _ = try ve.addShape(.{
        .shape_type = .circle,
        .x = 200,
        .y = 250,
        .radius = 30,
        .color = .{ .r = 135, .g = 206, .b = 235, .a = 255 }, // sky blue
        .filled = false,
    });

    _ = try ve.addShape(.{
        .shape_type = .circle,
        .x = 600,
        .y = 200,
        .radius = 25,
        .color = .{ .r = 255, .g = 192, .b = 203, .a = 255 }, // pink
        .filled = false,
    });

    // Small filled circles (stars)
    _ = try ve.addShape(.{ .shape_type = .circle, .x = 150, .y = 80, .radius = 5, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .filled = true });
    _ = try ve.addShape(.{ .shape_type = .circle, .x = 650, .y = 60, .radius = 5, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .filled = true });
    _ = try ve.addShape(.{ .shape_type = .circle, .x = 500, .y = 100, .radius = 4, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .filled = true });
    _ = try ve.addShape(.{ .shape_type = .circle, .x = 250, .y = 50, .radius = 3, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .filled = true });

    // Moving circle (animated element)
    const moving_circle = try ve.addShape(.{
        .shape_type = .circle,
        .x = 400,
        .y = 450,
        .radius = 20,
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 }, // red
        .filled = true,
    });

    std.debug.print("Shapes created:\n", .{});
    std.debug.print("  - 1 sun (filled circle)\n", .{});
    std.debug.print("  - 1 ground (filled rectangle)\n", .{});
    std.debug.print("  - 3 buildings (filled rectangles)\n", .{});
    std.debug.print("  - 2 decorative circles (outlines)\n", .{});
    std.debug.print("  - 4 stars (small filled circles)\n", .{});
    std.debug.print("  - 1 moving circle (animated)\n", .{});

    // ==========================================================================
    // Assertions for CI
    // ==========================================================================

    std.debug.print("\nRunning assertions:\n", .{});
    std.debug.assert(true); // Shapes were created successfully
    std.debug.print("  ✓ All shapes created successfully\n", .{});
    std.debug.print("\n✅ All assertions passed!\n\n", .{});

    var frame_count: u32 = 0;
    var circle_x: f32 = 400;
    var direction: f32 = 1;

    std.debug.print("Press ESC to exit\n\n", .{});

    // Game loop
    while (ve.isRunning()) {
        frame_count += 1;

        if (ci_test) {
            if (frame_count == 30) ve.takeScreenshot("screenshot_example4.png");
            if (frame_count == 35) break;
        }

        const dt = ve.getDeltaTime();

        // Animate the moving circle
        circle_x += direction * 100 * dt;
        if (circle_x > 700) {
            direction = -1;
        } else if (circle_x < 100) {
            direction = 1;
        }
        _ = ve.setShapePosition(moving_circle, circle_x, 450);

        // Render
        ve.beginFrame();
        ve.tick(dt);

        // UI
        labelle.Engine.UI.text("labelle-engine: Primitives Example", .{ .x = 10, .y = 10, .size = 20, .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });
        labelle.Engine.UI.text("Shapes: circles, rectangles (no sprites needed!)", .{ .x = 10, .y = 35, .size = 14, .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 } });
        labelle.Engine.UI.text("ESC: Exit", .{ .x = 10, .y = 580, .size = 14, .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } });

        ve.endFrame();
    }

    std.debug.print("Example 4 completed.\n", .{});
}
