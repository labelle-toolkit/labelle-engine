// Gizmo toggle script
// Press G to toggle gizmo visibility

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.log.info("[GizmoToggle] Press G to toggle gizmos, ESC to quit", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const input = game.getInput();

    // G - Toggle gizmos
    if (input.isKeyPressed(.g)) {
        const enabled = game.areGizmosEnabled();
        game.setGizmosEnabled(!enabled);
        std.log.info("[GizmoToggle] Gizmos {s}", .{if (!enabled) "enabled" else "disabled"});
    }

    // ESC - Quit
    if (input.isKeyPressed(.escape)) {
        game.quit();
    }
}
