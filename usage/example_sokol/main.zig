// ============================================================================
// Example: Sokol Backend with Full Hook Support
// ============================================================================
// This example demonstrates the Sokol backend with the hook system.
// Sokol uses a callback-based architecture where the main loop is driven by
// sokol_app callbacks (init, frame, cleanup, event).
//
// The key pattern is:
// 1. Import hook files from hooks/
// 2. Merge them with MergeEngineHooks
// 3. Create Game using GameWith(Hooks)
//
// Note: Shape rendering with sokol backend is tracked in:
// https://github.com/labelle-toolkit/labelle-gfx/issues/144
// ============================================================================

const std = @import("std");
const engine = @import("labelle-engine");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

const ProjectConfig = engine.ProjectConfig;

// Hook imports - generator scans hooks/ folder for .zig files
const game_hooks = @import("hooks/game_hooks.zig");

// Scene import
const initial_scene = @import("scenes/main.zon");

// Merge all hook files (generator does this automatically)
const Hooks = engine.MergeEngineHooks(.{
    game_hooks,
});

// Create Game with hooks enabled
const Game = engine.GameWith(Hooks);

// Registries
pub const Prefabs = engine.PrefabRegistry(.{});
pub const Components = engine.ComponentRegistry(struct {
    pub const Position = engine.Position;
    pub const Sprite = engine.Sprite;
    pub const Shape = engine.Shape;
    pub const Text = engine.Text;
});
pub const Scripts = engine.ScriptRegistry(struct {});
pub const Loader = engine.SceneLoader(Prefabs, Components, Scripts);

// Global state for sokol callback pattern
const State = struct {
    allocator: std.mem.Allocator = undefined,
    game: ?*Game = null,
    project: ?ProjectConfig = null,
    title: ?[:0]const u8 = null,
    frame_count: u32 = 0,
    ci_test: bool = false,
    initialized: bool = false,
};

var state: State = .{};
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

// Sokol app callbacks
export fn init() void {
    state.allocator = gpa.allocator();
    state.ci_test = std.posix.getenv("CI_TEST") != null;

    // Initialize sokol_gfx
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Initialize sokol_gl for immediate-mode drawing
    sgl.setup(.{
        .logger = .{ .func = sokol.log.func },
    });

    // Load project config
    state.project = ProjectConfig.load(state.allocator, "project.labelle") catch |err| {
        std.debug.print("Failed to load project.labelle: {any}\n", .{err});
        return;
    };

    // Convert title to sentinel-terminated string
    state.title = state.allocator.dupeZ(u8, state.project.?.window.title) catch {
        std.debug.print("Failed to allocate title\n", .{});
        return;
    };

    std.log.info("", .{});
    std.log.info("=== Sokol Backend Example ===", .{});
    std.log.info("", .{});
    std.log.info("This example shows:", .{});
    std.log.info("  - Sokol callback-based architecture", .{});
    std.log.info("  - Full hook system support (game_init, scene_load, etc.)", .{});
    std.log.info("  - scene_before_load, scene_load, and scene_unload hooks", .{});
    std.log.info("", .{});

    // Initialize game
    const game_ptr = state.allocator.create(Game) catch {
        std.debug.print("Failed to allocate game\n", .{});
        return;
    };
    game_ptr.* = Game.init(state.allocator, .{
        .window = .{
            .width = state.project.?.window.width,
            .height = state.project.?.window.height,
            .title = state.title.?,
            .target_fps = state.project.?.window.target_fps,
            .hidden = state.ci_test,
        },
        .clear_color = .{ .r = 30, .g = 35, .b = 45 },
    }) catch |err| {
        std.debug.print("Failed to init game: {any}\n", .{err});
        state.allocator.destroy(game_ptr);
        return;
    };
    game_ptr.fixPointers();
    state.game = game_ptr;

    // Apply camera configuration from project
    if (state.project.?.camera.x != null or state.project.?.camera.y != null) {
        state.game.?.setCameraPosition(state.project.?.camera.x orelse 0, state.project.?.camera.y orelse 0);
    }
    if (state.project.?.camera.zoom != 1.0) {
        state.game.?.setCameraZoom(state.project.?.camera.zoom);
    }

    // Emit scene_before_load hook for initial scene (mirrors Game.setScene behavior)
    Game.HookDispatcher.emit(.{ .scene_before_load = .{ .name = initial_scene.name, .allocator = state.allocator } });

    // Create entities manually (like example_hooks_generator does)
    // This ensures proper pipeline tracking for rendering
    const game = state.game.?;

    // Create a circle
    const circle = game.createEntity();
    game.addComponent(engine.Position, circle, .{ .x = 400, .y = 300 });
    var circle_shape = engine.Shape.circle(50);
    circle_shape.color = .{ .r = 100, .g = 150, .b = 255, .a = 255 };
    game.addComponent(engine.Shape, circle, circle_shape);
    game.getPipeline().trackEntity(circle, .shape) catch {};

    // Create a rectangle
    const rect = game.createEntity();
    game.addComponent(engine.Position, rect, .{ .x = 250, .y = 200 });
    var rect_shape = engine.Shape.rectangle(120, 80);
    rect_shape.color = .{ .r = 255, .g = 100, .b = 100, .a = 255 };
    game.addComponent(engine.Shape, rect, rect_shape);
    game.getPipeline().trackEntity(rect, .shape) catch {};

    // Create another circle
    const circle2 = game.createEntity();
    game.addComponent(engine.Position, circle2, .{ .x = 550, .y = 400 });
    var circle2_shape = engine.Shape.circle(30);
    circle2_shape.color = .{ .r = 100, .g = 255, .b = 100, .a = 255 };
    game.addComponent(engine.Shape, circle2, circle2_shape);
    game.getPipeline().trackEntity(circle2, .shape) catch {};

    std.log.info("[main] Created 3 shapes", .{});

    // Emit scene_load hook for initial scene (mirrors Game.setScene behavior)
    Game.HookDispatcher.emit(.{ .scene_load = .{ .name = initial_scene.name } });

    state.initialized = true;
    std.debug.print("Sokol backend initialized successfully!\n", .{});
    std.debug.print("Window size: {}x{}\n", .{ sapp.width(), sapp.height() });
}

export fn frame() void {
    if (!state.initialized) return;

    state.frame_count += 1;

    // Get delta time (kept for future use)
    _ = sapp.frameDuration();

    // Sync render pipeline
    if (state.game) |game| {
        game.getPipeline().sync(game.getRegistry());

        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();
        re.endFrame();
    }

    // Auto-exit for CI testing
    if (state.ci_test and state.frame_count > 10) {
        sapp.quit();
    }
}

export fn cleanup() void {
    if (state.initialized) {
        // Emit scene_unload hook for initial scene on exit (mirrors Game.setScene behavior)
        Game.HookDispatcher.emit(.{ .scene_unload = .{ .name = initial_scene.name } });
    }

    if (state.game) |game| {
        game.deinit();
        state.allocator.destroy(game);
        state.game = null;
    }

    if (state.title) |title| {
        state.allocator.free(title);
        state.title = null;
    }

    if (state.project) |project| {
        project.deinit(state.allocator);
        state.project = null;
    }

    sgl.shutdown();
    sg.shutdown();
    _ = gpa.deinit();

    std.debug.print("Sokol backend cleanup complete.\n", .{});
}

export fn event(ev: ?*const sapp.Event) void {
    const e = ev orelse return;

    if (e.type == .KEY_DOWN) {
        switch (e.key_code) {
            .ESCAPE => sapp.quit(),
            else => {},
        }
    }
}

pub fn main() void {
    // Run sokol app
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Sokol Backend Example",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
