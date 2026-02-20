// Gizmo toggle script
// Demonstrates gizmo features:
// - Press G to toggle gizmo visibility
// - Press A to toggle velocity arrow gizmos
// - Press R to toggle ray gizmos
// - Arrow keys to pan camera (demonstrates world-space gizmos)
// - Press ESC to quit

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Color = engine.Color;

var show_arrows: bool = true;
var show_rays: bool = true;
var time: f32 = 0;
var camera_x: f32 = 400;
var camera_y: f32 = 300;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.log.info("[GizmoToggle] Press G to toggle gizmos, A for arrows, R for rays", .{});
    std.log.info("[GizmoToggle] Arrow keys to pan camera (gizmos move with world)", .{});
    std.log.info("[GizmoToggle] ESC to quit", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    time += dt;

    const input = game.getInput();

    // G - Toggle all gizmos
    if (input.isKeyPressed(.g)) {
        const enabled = game.gizmos.areEnabled();
        game.gizmos.setEnabled(!enabled);
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

    // Arrow keys - Pan camera (demonstrates world-space gizmos moving with camera)
    const camera_speed: f32 = 200;
    if (input.isKeyDown(.left)) {
        camera_x -= camera_speed * dt;
    }
    if (input.isKeyDown(.right)) {
        camera_x += camera_speed * dt;
    }
    if (input.isKeyDown(.up)) {
        camera_y += camera_speed * dt;
    }
    if (input.isKeyDown(.down)) {
        camera_y -= camera_speed * dt;
    }
    game.setCameraPosition(camera_x, camera_y);

    // Clear previous frame's standalone gizmos
    game.gizmos.clearGizmos();

    // Draw standalone gizmos (not bound to entities)
    if (show_arrows) {
        // Velocity arrow (simulated movement)
        const vel_x = @cos(time * 2) * 50;
        const vel_y = @sin(time * 2) * 30;
        game.gizmos.drawArrow(400, 300, 400 + vel_x, 300 + vel_y, Color{ .r = 0, .g = 255, .b = 100, .a = 255 });

        // Static direction arrows
        game.gizmos.drawArrow(100, 100, 150, 100, Color{ .r = 255, .g = 0, .b = 0, .a = 255 }); // Right
        game.gizmos.drawArrow(100, 100, 100, 150, Color{ .r = 0, .g = 255, .b = 0, .a = 255 }); // Down
    }

    if (show_rays) {
        // Rotating rays from center
        const ray_angle = time;
        const ray_dir_x = @cos(ray_angle);
        const ray_dir_y = @sin(ray_angle);
        game.gizmos.drawRay(400, 300, ray_dir_x, ray_dir_y, 100, Color{ .r = 255, .g = 255, .b = 0, .a = 200 });

        // Opposite ray
        game.gizmos.drawRay(400, 300, -ray_dir_x, -ray_dir_y, 80, Color{ .r = 255, .g = 100, .b = 255, .a = 200 });
    }

    // Draw some debug circles at fixed positions
    game.gizmos.drawCircle(200, 400, 20, Color{ .r = 100, .g = 100, .b = 255, .a = 150 });
    game.gizmos.drawCircle(600, 400, 15, Color{ .r = 255, .g = 100, .b = 100, .a = 150 });
}
