// Example: Hook System
//
// Demonstrates the labelle-engine hook system for observing
// engine lifecycle events with zero runtime overhead.

const std = @import("std");
const engine = @import("labelle-engine");

// Define hook handlers - only the hooks you care about
const MyHooks = struct {
    pub fn game_init(_: engine.HookPayload) void {
        std.log.info("[hook] Game initialized", .{});
    }

    pub fn game_deinit(_: engine.HookPayload) void {
        std.log.info("[hook] Game shutting down", .{});
    }

    pub fn frame_start(payload: engine.HookPayload) void {
        const info = payload.frame_start;
        // Only log every 60 frames to avoid spam
        if (info.frame_number % 60 == 0) {
            std.log.info("[hook] Frame {d} started (dt: {d:.3}ms)", .{
                info.frame_number,
                info.dt * 1000,
            });
        }
    }

    pub fn frame_end(payload: engine.HookPayload) void {
        const info = payload.frame_end;
        // Only log every 60 frames
        if (info.frame_number % 60 == 0) {
            std.log.info("[hook] Frame {d} ended", .{info.frame_number});
        }
    }

    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("[hook] Scene loaded: {s}", .{info.name});
    }

    pub fn scene_unload(payload: engine.HookPayload) void {
        const info = payload.scene_unload;
        std.log.info("[hook] Scene unloading: {s}", .{info.name});
    }
};

// Create Game type with hooks enabled
const Game = engine.GameWith(MyHooks);

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting game with hooks enabled...", .{});

    // Initialize game - game_init hook will fire
    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Hook System Example",
            .hidden = ci_test,
        },
    });
    game.fixPointers();
    defer game.deinit(); // game_deinit hook will fire

    // Register a simple scene
    try game.registerSceneSimple("main", loadMainScene);
    try game.setScene("main"); // scene_load hook will fire

    // Run the game - frame_start/frame_end hooks fire each frame
    // For CI testing, the callback stops after a few frames
    try game.runWithCallback(if (ci_test) ciTestCallback else null);
}

// CI test callback - stops after a few frames
var ci_frame_count: u32 = 0;
fn ciTestCallback(game: *Game, _: f32) void {
    ci_frame_count += 1;
    if (ci_frame_count >= 5) {
        game.quit();
    }
}

fn loadMainScene(_: *Game) !void {
    // Create some entities here
    std.log.info("Loading main scene...", .{});
}
