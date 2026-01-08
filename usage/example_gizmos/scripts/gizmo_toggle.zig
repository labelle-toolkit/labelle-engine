// Gizmo toggle script
// Demonstrates gizmo features:
// - Press G to toggle gizmo visibility
// - Press A to toggle velocity arrow gizmos
// - Press R to toggle ray gizmos
// - Press ESC to quit

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Color = engine.Color;

var show_arrows: bool = true;
var show_rays: bool = true;
var time: f32 = 0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.log.info("[GizmoToggle] Press G to toggle gizmos, A for arrows, R for rays, ESC to quit", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    time += dt;

    const input = game.getInput();

    // G - Toggle all gizmos
    if (input.isKeyPressed(.g)) {
        const enabled = game.areGizmosEnabled();
        game.setGizmosEnabled(!enabled);
        std.log.info("[GizmoToggle] Gizmos {s}", .{if (!enabled) "enabled" else "disabled"});
    }

    // A - Toggle arrow gizmos
    if (input.isKeyPressed(.a)) {
        show_arrows = !show_arrows;
        std.log.info("[GizmoToggle] Arrow gizmos {s}", .{if (show_arrows) "enabled" else "disabled"});
    }

    // R - Toggle ray gizmos
    if (input.isKeyPressed(.r)) {
        show_rays = !show_rays;
        std.log.info("[GizmoToggle] Ray gizmos {s}", .{if (show_rays) "enabled" else "disabled"});
    }

    // ESC - Quit
    if (input.isKeyPressed(.escape)) {
        game.quit();
    }

    // Clear previous frame's standalone gizmos
    game.clearGizmos();

    // Draw standalone gizmos (not bound to entities)
    if (show_arrows) {
        // Velocity arrow (simulated movement)
        const vel_x = @cos(time * 2) * 50;
        const vel_y = @sin(time * 2) * 30;
        game.drawArrow(400, 300, 400 + vel_x, 300 + vel_y, Color{ .r = 0, .g = 255, .b = 100, .a = 255 });

        // Static direction arrows
        game.drawArrow(100, 100, 150, 100, Color{ .r = 255, .g = 0, .b = 0, .a = 255 }); // Right
        game.drawArrow(100, 100, 100, 150, Color{ .r = 0, .g = 255, .b = 0, .a = 255 }); // Down
    }

    if (show_rays) {
        // Rotating rays from center
        const ray_angle = time;
        const ray_dir_x = @cos(ray_angle);
        const ray_dir_y = @sin(ray_angle);
        game.drawRay(400, 300, ray_dir_x, ray_dir_y, 100, Color{ .r = 255, .g = 255, .b = 0, .a = 200 });

        // Opposite ray
        game.drawRay(400, 300, -ray_dir_x, -ray_dir_y, 80, Color{ .r = 255, .g = 100, .b = 255, .a = 200 });
    }

    // Draw some debug circles at fixed positions
    game.drawCircle(200, 400, 20, Color{ .r = 100, .g = 100, .b = 255, .a = 150 });
    game.drawCircle(600, 400, 15, Color{ .r = 255, .g = 100, .b = 100, .a = 150 });
}
