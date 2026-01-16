//! Android Main Entry Point (No Physics)
//!
//! This is a simplified Android entry point that verifies the engine
//! builds correctly for Android without physics. Physics is disabled
//! due to Box2D duplicate symbol issues in shared libraries.
//!
//! TODO: Fix Box2D linking for Android and merge with full android_main.zig

const std = @import("std");
const engine = @import("labelle-engine");

// Sokol bindings
const sokol = engine.sokol;
const sg = sokol.gfx;
const sapp = sokol.app;

const Game = engine.Game;

// ============================================================================
// Global State
// ============================================================================

const State = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    game: ?*Game = null,
    initialized: bool = false,
    ci_test: bool = true,
    frame_count: u32 = 0,
};

var state: State = .{};
var game_storage: Game = undefined;

// ============================================================================
// Sokol App Callbacks
// ============================================================================

export fn init() callconv(.c) void {
    if (state.initialized) return;

    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    state.allocator = std.heap.page_allocator;

    game_storage = Game.init(state.allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Android Build Test",
            .target_fps = 60,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    }) catch |err| {
        std.debug.print("Failed to initialize game: {}\n", .{err});
        sapp.quit();
        return;
    };
    state.game = &game_storage;
    state.game.?.fixPointers();

    state.initialized = true;
    std.debug.print("Android build test initialized (no physics)!\n", .{});
}

export fn frame() callconv(.c) void {
    if (!state.initialized or state.game == null) return;

    state.frame_count += 1;
    if (state.ci_test) {
        if (state.frame_count > 10) {
            sapp.quit();
            return;
        }
        return;
    }

    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.118, .g = 0.137, .b = 0.176, .a = 1.0 },
    };
    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    });

    const re = state.game.?.getRetainedEngine();
    re.beginFrame();
    re.render();
    re.endFrame();

    sg.endPass();
    sg.commit();
}

export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;
    if (e.type == .KEY_DOWN and e.key_code == .ESCAPE) {
        sapp.quit();
    }
}

export fn cleanup() callconv(.c) void {
    if (state.game) |game| {
        game.deinit();
        state.game = null;
    }
    sg.shutdown();
    std.debug.print("Android build test cleanup complete.\n", .{});
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Android Build Test",
        .high_dpi = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
