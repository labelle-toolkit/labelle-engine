// ============================================================================
// Android Bouncing Ball Demo
// ============================================================================
// Colorful shapes bouncing around the screen.
// Uses sokol backend with GLES3 for Android.
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("labelle-engine");

// Sokol bindings - re-exported from engine for Android callback architecture
const sokol = engine.sokol;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

// Import components
const Velocity_comp = @import("components/Velocity.zig");
pub const Velocity = Velocity_comp.Velocity;

// Import scripts
const bouncing_ball_script = @import("scripts/bouncing_ball.zig");

// Import hooks
const game_hooks = @import("hooks/game_hooks.zig");

const main_module = @This();

// Registries
pub const Prefabs = engine.PrefabRegistry(.{});
pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
    pub const Velocity = main_module.Velocity;
});
pub const Scripts = engine.ScriptRegistry(struct {
    pub const bouncing_ball = bouncing_ball_script;
});

// Hooks
const Hooks = engine.MergeEngineHooks(.{game_hooks});
const Game = engine.GameWith(Hooks);

// Scene loader
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
pub const initial_scene = @import("scenes/main.zon");

// Global state for sokol callback pattern
const State = struct {
    allocator: std.mem.Allocator = undefined,
    game: ?*Game = null,
    scene: ?*engine.Scene = null,
    initialized: bool = false,
    frame_count: u32 = 0,
};

var state: State = .{};

// Allocated storage for game and scene
var game_storage: Game = undefined;
var scene_storage: engine.Scene = undefined;

// Sokol app callbacks for Android
export fn init() callconv(.c) void {
    // Initialize sokol_gfx with sokol_app's rendering context
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Initialize sokol_gl for 2D drawing
    sgl.setup(.{
        .logger = .{ .func = sokol.log.func },
    });

    // Use page allocator for Android
    state.allocator = std.heap.page_allocator;

    // Initialize game
    game_storage = Game.init(state.allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Bouncing Ball Demo",
            .target_fps = 60,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    }) catch |err| {
        std.log.err("Failed to initialize game: {}", .{err});
        sapp.quit();
        return;
    };
    state.game = &game_storage;
    state.game.?.fixPointers();

    // Apply camera
    state.game.?.setCameraPosition(400, 300);

    const ctx = engine.SceneContext.init(state.game.?);

    // Emit scene_before_load hook
    Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = state.allocator } });

    // Load initial scene
    scene_storage = Loader.load(initial_scene, ctx) catch |err| {
        std.log.err("Failed to load scene: {}", .{err});
        sapp.quit();
        return;
    };
    state.scene = &scene_storage;

    // Emit scene_load hook
    Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    state.initialized = true;
    std.log.info("Android sokol backend initialized!", .{});
    std.log.info("Screen size: {}x{}", .{ sapp.width(), sapp.height() });
}

export fn frame() callconv(.c) void {
    if (!state.initialized or state.game == null or state.scene == null) return;

    state.frame_count += 1;

    // Get delta time from sokol
    const dt: f32 = @floatCast(sapp.frameDuration());

    // Update scene
    state.scene.?.update(dt);

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

    // End sokol render pass
    sg.endPass();
    sg.commit();
}

export fn cleanup() callconv(.c) void {
    // Emit scene_unload hook
    if (state.initialized and state.game != null) {
        if (state.game.?.getCurrentSceneName() == null) {
            Game.HookDispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
        }
    }

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
    sgl.shutdown();
    sg.shutdown();

    std.log.info("Android cleanup complete.", .{});
}

export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;

    switch (e.type) {
        // Android touch events
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            // Touch handling - can be forwarded to game input
        },
        // Android back button
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.quit();
            }
        },
        // Android lifecycle
        .SUSPENDED => {
            std.log.info("App suspended", .{});
        },
        .RESUMED => {
            std.log.info("App resumed", .{});
        },
        .QUIT_REQUESTED => {
            sapp.quit();
        },
        else => {},
    }
}

// Entry point - sokol_main for Android
pub export fn sokol_main() callconv(.c) sapp.Desc {
    return .{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Bouncing Ball Demo",
        .high_dpi = true,
        .fullscreen = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    };
}
