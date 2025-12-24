const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const Game = engine.Game;

test {
    zspec.runAll(@This());
}

pub const GAME_EXPORTS = struct {
    pub const FULLSCREEN_METHODS = struct {
        test "Game has toggleFullscreen method" {
            try expect.toBeTrue(@hasDecl(Game, "toggleFullscreen"));
        }

        test "Game has setFullscreen method" {
            try expect.toBeTrue(@hasDecl(Game, "setFullscreen"));
        }

        test "Game has isFullscreen method" {
            try expect.toBeTrue(@hasDecl(Game, "isFullscreen"));
        }
    };

    pub const SCREEN_SIZE_METHODS = struct {
        test "Game has screenSizeChanged method" {
            try expect.toBeTrue(@hasDecl(Game, "screenSizeChanged"));
        }

        test "Game has getScreenSize method" {
            try expect.toBeTrue(@hasDecl(Game, "getScreenSize"));
        }

        test "ScreenSize type is exported" {
            try expect.toBeTrue(@hasDecl(engine, "ScreenSize"));
        }

        test "ScreenSize has width and height fields" {
            const ScreenSize = engine.ScreenSize;
            try expect.toBeTrue(@hasField(ScreenSize, "width"));
            try expect.toBeTrue(@hasField(ScreenSize, "height"));
        }
    };
};
