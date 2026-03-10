// Scene menu script - demonstrates scene switching with GUI buttons.
//
// On menu: shows a "Play" button. On game: shows a "Back" button.
// Press 1 for game scene, ESC to return to menu.

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
}

pub fn deinit() void {}

fn isOnMenu(game: *Game) bool {
    const name = game.getCurrentSceneName() orelse return false;
    return std.mem.eql(u8, name, "menu");
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const input = game.getInput();
    const on_menu = isOnMenu(game);

    if (on_menu) {
        if (game.gui.button(.{
            .text = "Play Game",
            .position = .{ .x = 300, .y = 280 },
            .size = .{ .width = 200, .height = 40 },
        })) {
            game.queueSceneChange("game");
            return;
        }
    } else {
        if (game.gui.button(.{
            .text = "Back to Menu",
            .position = .{ .x = 10, .y = 10 },
            .size = .{ .width = 120, .height = 30 },
        })) {
            game.queueSceneChange("menu");
            return;
        }
    }

    if (input.isKeyPressed(.one) and on_menu) {
        game.queueSceneChange("game");
    } else if (input.isKeyPressed(.escape) and !on_menu) {
        game.queueSceneChange("menu");
    }
}
