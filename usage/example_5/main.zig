// Example 5: Game Facade with Multiple Scenes
//
// Demonstrates the simplified Game API for GUI-generated projects:
// - Game facade encapsulates engine, registry, and scene management
// - Multiple scenes with transitions (menu -> game)
// - Folder-based organization for components, scripts, and scenes

const std = @import("std");
const engine = @import("labelle-engine");
const labelle = @import("labelle");

// Import components
const velocity_mod = @import("components/velocity.zig");
const player_mod = @import("components/player.zig");
const button_mod = @import("components/button.zig");
const collectible_mod = @import("components/collectible.zig");

pub const Velocity = velocity_mod.Velocity;
pub const Player = player_mod.Player;
pub const Button = button_mod.Button;
pub const Collectible = collectible_mod.Collectible;

const main_module = @This();

// Component registry
const Components = engine.ComponentRegistry(struct {
    pub const Velocity = main_module.Velocity;
    pub const Player = main_module.Player;
    pub const Button = main_module.Button;
    pub const Collectible = main_module.Collectible;
});

// Empty prefabs and scripts registries (for this example)
const Prefabs = engine.PrefabRegistry(.{});
const Scripts = engine.ScriptRegistry(struct {});

// Scene loader type
const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// Game state
var game_started = false;
var score: u32 = 0;
var frame_count: u32 = 0;

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize game with simple config
    var game = try engine.Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Example 5: Multi-Scene Game",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 40, .g = 44, .b = 52 },
    });
    defer game.deinit();

    // Register scenes
    try game.registerScene("menu", Loader, @import("scenes/menu_scene.zon"), .{
        .onLoad = onMenuLoad,
    });
    try game.registerScene("game", Loader, @import("scenes/game_scene.zon"), .{
        .onLoad = onGameLoad,
    });

    // Start with menu scene
    try game.setScene("menu");

    // Run game loop with custom frame callback
    try game.runWithCallback(frameUpdate);

    // Take screenshot before exit (for CI)
    game.takeScreenshot("screenshot_example5.png");

    std.debug.print("Example 5 completed. Score: {d}\n", .{score});
}

fn onMenuLoad(_: *engine.Game) void {
    std.debug.print("Menu scene loaded\n", .{});
    game_started = false;
}

fn onGameLoad(_: *engine.Game) void {
    std.debug.print("Game scene loaded\n", .{});
    game_started = true;
    score = 0;
}

fn frameUpdate(game: *engine.Game, dt: f32) void {
    _ = dt;
    frame_count += 1;

    // Auto-transition from menu to game after 60 frames (for demo/CI)
    if (!game_started and frame_count > 60) {
        std.debug.print("Transitioning to game scene...\n", .{});
        game.queueSceneChange("game");
    }

    // Auto-quit after playing for a bit (for demo/CI)
    if (game_started and frame_count > 180) {
        score = 100; // Demo score
        game.quit();
    }
}

// Tests for CI
test "example_5 structure" {
    // Verify components exist
    _ = Velocity;
    _ = Player;
    _ = Button;
    _ = Collectible;

    // Verify component registry works
    try std.testing.expect(Components.has("Velocity"));
    try std.testing.expect(Components.has("Player"));
    try std.testing.expect(Components.has("Button"));
    try std.testing.expect(Components.has("Collectible"));
}
