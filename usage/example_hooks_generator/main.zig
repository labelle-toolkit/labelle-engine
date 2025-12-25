// ============================================================================
// Example: Hooks Folder Pattern
// ============================================================================
// This example demonstrates how the generator wires up hooks from the
// hooks/ folder. In a generated project, this file would be auto-generated.
//
// The key pattern is:
// 1. Import hook files from hooks/
// 2. Merge them with MergeEngineHooks
// 3. Create Game using GameWith(Hooks)
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");

const ProjectConfig = engine.ProjectConfig;

// Hook imports - generator scans hooks/ folder for .zig files
const game_hooks = @import("hooks/game_hooks.zig");

// Merge all hook files (generator does this automatically)
const Hooks = engine.MergeEngineHooks(.{
    game_hooks,
    // Additional hook files would be listed here
});

// Create Game with hooks enabled
const Game = engine.GameWith(Hooks);

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project = try ProjectConfig.load(allocator, "project.labelle");
    defer project.deinit(allocator);

    const title = try allocator.dupeZ(u8, project.window.title);
    defer allocator.free(title);

    var game = try Game.init(allocator, .{
        .window = .{
            .width = project.window.width,
            .height = project.window.height,
            .title = title,
            .target_fps = project.window.target_fps,
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    });
    game.fixPointers();
    defer game.deinit();

    // Register scene with shapes
    try game.registerSceneSimple("main", loadMainScene);
    try game.setScene("main");

    if (ci_test) return;

    try game.run();
}

fn loadMainScene(_: *Game) !void {
    // This function is called when the scene loads.
    // The hooks in hooks/game_hooks.zig will automatically receive:
    // - scene_load event (with scene name "main")
    // - entity_created events (for any entities created here)
    std.log.info("[main] Main scene loaded - hooks are firing!", .{});
}
