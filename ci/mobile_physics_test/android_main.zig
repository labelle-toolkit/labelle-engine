//! Android Main Entry Point for labelle-engine games
//!
//! This file provides the entry point for Android NativeActivity.
//! It imports the project's main module for registries and scenes,
//! and sets up the sokol-based game loop.

const std = @import("std");
const engine = @import("labelle-engine");

// Import project's main module for registries and scenes
const project = @import("main");

// Sokol bindings - re-exported from engine for Android callback architecture
const sokol = engine.sokol;
const sg = sokol.gfx;
const sapp = sokol.app;

// Game types from engine
const Game = engine.Game;

// Use project's registries and loader
const Loader = project.Loader;
const initial_scene = project.initial_scene;

// ============================================================================
// Global State
// ============================================================================

const Scene = engine.scene.Scene;

const State = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    game: ?*Game = null,
    scene: ?*Scene = null,
    initialized: bool = false,
    ci_test: bool = true, // Always run in CI mode for automated builds
    frame_count: u32 = 0,
};

var state: State = .{};

// Allocated storage for game and scene (needed because sokol callbacks can't return errors)
var game_storage: Game = undefined;
var scene_storage: Scene = undefined;

// ============================================================================
// Sokol App Callbacks
// ============================================================================

/// Initialize the graphics system and load initial scene
export fn init() callconv(.c) void {
    if (state.initialized) return;

    // Initialize sokol_gfx with sokol_app's rendering context
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Use page allocator for simplicity in callback context
    state.allocator = std.heap.page_allocator;

    // Initialize game with embedded config
    game_storage = Game.init(state.allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Mobile Physics Test",
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

    // Load initial scene from project
    const ctx = engine.SceneContext.init(state.game.?);
    scene_storage = Loader.load(initial_scene, ctx) catch |err| {
        std.debug.print("Failed to load scene: {}\n", .{err});
        sapp.quit();
        return;
    };
    state.scene = &scene_storage;

    state.initialized = true;

    std.debug.print("Android labelle-engine initialized successfully!\n", .{});
}

/// Called every frame - update game state and render
export fn frame() callconv(.c) void {
    if (!state.initialized or state.game == null) return;

    // CI test mode: exit after 10 frames
    state.frame_count += 1;
    if (state.ci_test) {
        if (state.frame_count > 10) {
            sapp.quit();
            return;
        }
        // Skip rendering in CI mode
        return;
    }

    // Get delta time from sokol
    const dt: f32 = @floatCast(sapp.frameDuration());

    // Update scene if loaded (runs scripts, etc.)
    if (state.scene) |scene| {
        scene.update(dt);
    }

    // Sync ECS components to graphics
    state.game.?.getPipeline().sync(state.game.?.getRegistry());

    // Begin sokol render pass
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.118, .g = 0.137, .b = 0.176, .a = 1.0 },
    };
    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    });

    // Render using the retained engine
    const re = state.game.?.getRetainedEngine();
    re.beginFrame();
    re.render();
    re.endFrame();

    // End sokol render pass and commit
    sg.endPass();
    sg.commit();
}

/// Handle input events
export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;

    switch (e.type) {
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.quit();
            }
        },
        else => {},
    }
}

/// Cleanup resources on app termination
export fn cleanup() callconv(.c) void {
    // Cleanup scene
    if (state.scene) |scene| {
        scene.deinit();
        state.scene = null;
    }

    // Cleanup game
    if (state.game) |game| {
        game.deinit();
        state.game = null;
    }

    // Cleanup sokol
    sg.shutdown();

    std.debug.print("Android labelle-engine cleanup complete.\n", .{});
}

// ============================================================================
// Entry Point (Android uses ANativeActivity_onCreate)
// ============================================================================

/// Android entry point - sokol handles the NativeActivity callbacks internally
/// This is called by sokol's Android glue code
pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Mobile Physics Test",
        .high_dpi = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
