//! iOS Main Entry Point for labelle-engine games
//!
//! This file provides the sokol_app callbacks for iOS:
//! - init: Initialize graphics and load initial scene
//! - frame: Update and render each frame
//! - event: Handle touch and keyboard input
//! - cleanup: Free resources on app termination
//!
//! Touch events are tracked and accessible via getTouchCount/getTouch.
//!
//! This template integrates with labelle-engine for full game support
//! including scenes, ECS, physics, and scripts.

const std = @import("std");
const engine = @import("labelle-engine");

// Import project's main module for registries and scenes
const project = @import("main");

// Sokol bindings - re-exported from engine for iOS callback architecture
// This avoids module conflicts when both engine and app import sokol
const sokol = engine.sokol;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

// Game types from engine
const Game = engine.Game;

// Use project's registries and loader
const Loader = project.Loader;
const initial_scene = project.initial_scene;

// ============================================================================
// Touch Input Types
// ============================================================================

pub const TouchPhase = enum {
    began,
    moved,
    ended,
    cancelled,
};

pub const Touch = struct {
    id: u64,
    x: f32,
    y: f32,
    phase: TouchPhase,
};

const MAX_TOUCHES = 10;

// ============================================================================
// Global State
// ============================================================================

const Scene = engine.scene.Scene;

const State = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    game: ?*Game = null,
    scene: ?*Scene = null,
    initialized: bool = false,
    should_quit: bool = false,
    ci_test: bool = false,
    frame_count: u32 = 0,

    // Touch input state
    touches: [MAX_TOUCHES]Touch = undefined,
    touch_count: u32 = 0,

    // Screen dimensions (updated on resize)
    screen_width: f32 = 0,
    screen_height: f32 = 0,
};

var state: State = .{};

// Allocated storage for game and scene (needed because sokol callbacks can't return errors)
var game_storage: Game = undefined;
var scene_storage: Scene = undefined;

// ============================================================================
// Project Configuration (embedded at compile time for iOS)
// ============================================================================

// TODO: These should be generated from project.labelle
const window_width: u32 = 800;
const window_height: u32 = 600;
const window_title = "Labelle Game";
const clear_color: engine.Color = .{ .r = 30, .g = 35, .b = 45 };

// ============================================================================
// Sokol App Callbacks
// ============================================================================

/// Initialize the graphics system and load initial scene
export fn init() callconv(.c) void {
    // Ensure init is idempotent in case the OS restarts callbacks.
    if (state.initialized) return;

    // CI test mode detection:
    // - Prefer argv flag (reliable via `simctl launch ... --args`).
    // - Fall back to env var for local/manual runs.
    state.ci_test = false;
    {
        var args = std.process.args();
        // argv[0]
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ci-test")) {
                state.ci_test = true;
                break;
            }
        }
    }
    if (!state.ci_test) {
        state.ci_test = std.posix.getenv("CI_TEST") != null;
    }

    // Initialize sokol_gfx with sokol_app's rendering context
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Initialize sokol_gl for 2D drawing (must be after sg.setup)
    // Disabled here: it registers a commit listener and can fail/flake on Simulator.
    // If needed for projects, this should be initialized by the graphics backend.

    // Store initial screen dimensions
    state.screen_width = @floatFromInt(sapp.width());
    state.screen_height = @floatFromInt(sapp.height());

    // Initialize touch state
    for (&state.touches) |*touch| {
        touch.* = .{ .id = 0, .x = 0, .y = 0, .phase = .ended };
    }
    state.touch_count = 0;

    // Use page allocator for simplicity in callback context
    state.allocator = std.heap.page_allocator;

    // Initialize game with embedded config (iOS doesn't load from filesystem)
    game_storage = Game.init(state.allocator, .{
        .window = .{
            .width = window_width,
            .height = window_height,
            .title = window_title,
            .target_fps = 60,
        },
        .clear_color = clear_color,
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

    std.debug.print("labelle-engine iOS initialized successfully!\n", .{});
    std.debug.print("Scene: {s}\n", .{initial_scene.name});
    std.debug.print("Window size: {}x{}\n", .{ sapp.width(), sapp.height() });
}

/// Called every frame - update game state and render
export fn frame() callconv(.c) void {
    if (!state.initialized or state.game == null) return;

    // CI test mode: exit after 10 frames
    state.frame_count += 1;
    if (state.ci_test) {
        if (state.frame_count > 10) {
            state.should_quit = true;
            sapp.quit();
            return;
        }
    }

    // Update screen dimensions (may change on rotation)
    state.screen_width = @floatFromInt(sapp.width());
    state.screen_height = @floatFromInt(sapp.height());

    // Get delta time from sokol
    const dt: f32 = @floatCast(sapp.frameDuration());

    // Update scene if loaded (runs scripts, etc.)
    if (state.scene) |scene| {
        scene.update(dt);
    }

    // Sync ECS components to graphics
    state.game.?.getPipeline().sync(state.game.?.getRegistry());

    // Clear per-frame touch state (touches that ended last frame)
    var i: u32 = 0;
    while (i < state.touch_count) {
        if (state.touches[i].phase == .ended or state.touches[i].phase == .cancelled) {
            // Remove this touch by shifting remaining touches
            var j = i;
            while (j + 1 < state.touch_count) : (j += 1) {
                state.touches[j] = state.touches[j + 1];
            }
            state.touch_count -= 1;
        } else {
            i += 1;
        }
    }

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

/// Handle input events (touch, keyboard)
export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;

    switch (e.type) {
        // Touch events
        .TOUCHES_BEGAN => handleTouchEvent(e, .began),
        .TOUCHES_MOVED => handleTouchEvent(e, .moved),
        .TOUCHES_ENDED => handleTouchEvent(e, .ended),
        .TOUCHES_CANCELLED => handleTouchEvent(e, .cancelled),

        // Keyboard (for simulator testing)
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.quit();
            }
        },

        // Window resize (device rotation)
        .RESIZED => {
            state.screen_width = @floatFromInt(sapp.width());
            state.screen_height = @floatFromInt(sapp.height());
            std.debug.print("Screen resized to {d:.0}x{d:.0}\n", .{ state.screen_width, state.screen_height });
        },

        // App lifecycle
        .SUSPENDED => {
            std.debug.print("App suspended\n", .{});
        },
        .RESUMED => {
            std.debug.print("App resumed\n", .{});
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

    // Cleanup sokol in reverse order of initialization
    sgl.shutdown();
    sg.shutdown();

    std.debug.print("labelle-engine iOS cleanup complete.\n", .{});
}

// ============================================================================
// Touch Handling
// ============================================================================

fn handleTouchEvent(e: *const sapp.Event, phase: TouchPhase) void {
    // Process each touch in the event
    var i: u32 = 0;
    while (i < e.num_touches) : (i += 1) {
        const sokol_touch = e.touches[i];
        if (!sokol_touch.changed) continue;

        const touch = Touch{
            .id = sokol_touch.identifier,
            .x = sokol_touch.pos_x,
            .y = sokol_touch.pos_y,
            .phase = phase,
        };

        // Find existing touch with same ID or add new one
        var found = false;
        for (state.touches[0..state.touch_count]) |*existing| {
            if (existing.id == touch.id) {
                existing.* = touch;
                found = true;
                break;
            }
        }

        if (!found and state.touch_count < MAX_TOUCHES) {
            state.touches[state.touch_count] = touch;
            state.touch_count += 1;
        }

        // Log touch event
        std.log.debug("Touch {s}: id={d} pos=({d:.1}, {d:.1})", .{
            @tagName(phase),
            touch.id,
            touch.x,
            touch.y,
        });
    }
}

// ============================================================================
// Public API for Game Integration
// ============================================================================

/// Get current touch count
pub fn getTouchCount() u32 {
    return state.touch_count;
}

/// Get touch at index
pub fn getTouch(index: u32) ?Touch {
    if (index < state.touch_count) {
        return state.touches[index];
    }
    return null;
}

/// Get screen dimensions
pub fn getScreenSize() struct { width: f32, height: f32 } {
    return .{ .width = state.screen_width, .height = state.screen_height };
}

// ============================================================================
// Entry Point
// ============================================================================

/// Entry point - uses sokol's SOKOL_NO_ENTRY mode via sapp.run()
/// sokol-zig defines SOKOL_NO_ENTRY for all non-Android platforms,
/// so we call sapp.run() ourselves rather than exporting sokol_main.
pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = window_width,
        .height = window_height,
        .window_title = window_title,
        .high_dpi = true,
        .fullscreen = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
