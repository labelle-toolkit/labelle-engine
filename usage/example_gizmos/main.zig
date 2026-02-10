// Example: Gizmos (Debug Visualizations)
//
// Demonstrates the labelle-engine gizmos system:
// - Prefabs with .gizmos field for debug-only visualizations
// - Runtime toggle with game.setGizmosEnabled()
// - Standalone gizmos (drawArrow, drawRay, drawCircle, etc.)
// - Gizmos are automatically stripped in release builds
//
// Controls:
// - G: Toggle gizmo visibility
// - A: Toggle arrow gizmos
// - R: Toggle ray gizmos
// - ESC: Quit

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;

// Import prefabs
const player_prefab = @import("prefabs/player.zon");
const enemy_prefab = @import("prefabs/enemy.zon");

// Import scripts
const gizmo_toggle_script = @import("scripts/gizmo_toggle.zig");

// Create registries
pub const Prefabs = engine.PrefabRegistry(.{
    .player = player_prefab,
    .enemy = enemy_prefab,
});

// Register engine built-in components used in the scene
pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
});

pub const Scripts = engine.ScriptRegistry(struct {
    pub const gizmo_toggle = gizmo_toggle_script;
});

pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// Import scene
const main_scene = @import("scenes/main.zon");

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("", .{});
    std.log.info("=== Gizmos Example ===", .{});
    std.log.info("", .{});
    std.log.info("Gizmos are debug-only visualizations:", .{});
    std.log.info("  - Labels above entities (.Text)", .{});
    std.log.info("  - Origin markers (.Shape)", .{});
    std.log.info("  - Auto-sized bounding boxes (.BoundingBox)", .{});
    std.log.info("  - Standalone gizmos (drawArrow, drawRay)", .{});
    std.log.info("", .{});
    std.log.info("Press G to toggle gizmos", .{});
    std.log.info("Arrow keys to pan camera (gizmos move with world)", .{});
    std.log.info("Press ESC to quit", .{});
    std.log.info("", .{});

    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Gizmos Example - Press G to toggle",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    defer game.deinit();

    // Load the scene
    const ctx = engine.SceneContext.init(&game);
    var scene = try Loader.load(main_scene, ctx);
    defer scene.deinit();

    if (ci_test) return;

    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        scene.update(dt);
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        game.gizmos.renderStandaloneGizmos(); // Draw standalone gizmos on top
        re.endFrame();
    }
}
