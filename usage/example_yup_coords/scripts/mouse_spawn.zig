//! Mouse Spawn Script
//!
//! Demonstrates Y-up coordinate system by spawning circles at mouse click positions.
//! Uses game.input_mixin.getMousePosition() which returns Y-up coordinates.

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;

/// Random number generator for circle colors
var rng: std.Random.Xoshiro256 = std.Random.Xoshiro256.init(12345);

pub fn update(
    game: *Game,
    scene: *Scene,
    dt: f32,
) void {
    _ = scene;
    _ = dt;

    const input = game.getInput();

    // Spawn circle on left mouse click
    if (input.isMouseButtonPressed(.left)) {
        // Get mouse position in Y-UP game coordinates
        // This uses game.input_mixin.getMousePosition() which transforms screen coords to game coords
        const mouse_pos = game.input_mixin.getMousePosition();

        // Log the coordinates to verify Y-up behavior
        std.log.info("Mouse click at game coords: ({d:.0}, {d:.0})", .{ mouse_pos.x, mouse_pos.y });

        // Create new entity with a circle at the clicked position
        const entity = game.createEntity();

        // Add position component (using Y-up coordinates from mouse)
        game.addComponent(Position, entity, Position{
            .x = mouse_pos.x,
            .y = mouse_pos.y,
        });

        // Add shape component with random color
        const random = rng.random();
        var shape = Shape.circle(15);
        shape.color = .{
            .r = @as(u8, @intCast(100 + random.intRangeAtMost(u8, 0, 155))),
            .g = @as(u8, @intCast(100 + random.intRangeAtMost(u8, 0, 155))),
            .b = @as(u8, @intCast(100 + random.intRangeAtMost(u8, 0, 155))),
            .a = 255,
        };
        game.addShape(entity, shape) catch {
            std.log.err("Failed to add shape to entity", .{});
        };
    }

    // Quit on escape
    if (input.isKeyPressed(.escape)) {
        game.quit();
    }

    // Toggle fullscreen on F11
    if (input.isKeyPressed(.f11)) {
        game.toggleFullscreen();
    }
}
