//! Y-Up Coordinate System Example
//!
//! This example demonstrates the Y-up coordinate system where:
//! - Origin (0, 0) is at the bottom-left corner
//! - Higher Y values appear higher on screen
//! - Mouse/touch input is automatically transformed to Y-up coordinates
//!
//! Visual validation:
//! - Red circle at Y=50 should appear at BOTTOM
//! - Green circle at Y=300 should appear in MIDDLE
//! - Blue circle at Y=550 should appear at TOP
//! - Yellow square at (0,0) should be at bottom-left corner
//!
//! Interactive validation:
//! - Click anywhere to spawn circles
//! - Circles should appear WHERE you click (not mirrored)
//! - Console logs show Y-up coordinates

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;

const mouse_spawn_script = @import("scripts/mouse_spawn.zig");

pub const Prefabs = engine.PrefabRegistry(.{});

pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const mouse_spawn = mouse_spawn_script;
});

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/coords_demo.zon");

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Y-Up Coordinate System Demo",
            .target_fps = 60,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    defer game.deinit();

    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(initial_scene, ctx);
    defer scene.deinit();

    if (ci_test) {
        std.log.info("CI test mode: Y-up coordinate example initialized successfully", .{});
        return;
    }

    std.log.info("Y-Up Coordinate System Demo", .{});
    std.log.info("- Red circle (Y=50) should be at BOTTOM", .{});
    std.log.info("- Green circle (Y=300) should be in MIDDLE", .{});
    std.log.info("- Blue circle (Y=550) should be at TOP", .{});
    std.log.info("- Click to spawn circles at mouse position", .{});

    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        scene.update(dt);
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        re.endFrame();
    }
}
