// Game facade - simplified API for GUI-generated projects
//
// Provides a high-level interface that encapsulates:
// - VisualEngine initialization
// - ECS Registry management
// - Multi-scene support with transitions
// - Default game loop
//
// Example usage:
//
//   var game = try Game.init(allocator, .{
//       .window = .{ .width = 800, .height = 600, .title = "My Game" },
//   });
//   defer game.deinit();
//
//   try game.registerScene("main_menu", MainMenuLoader, main_menu_scene);
//   try game.setScene("main_menu");
//   try game.run();

const std = @import("std");
const labelle = @import("labelle");
const ecs = @import("ecs");
const scene_mod = @import("scene.zig");

const Allocator = std.mem.Allocator;
const VisualEngine = labelle.visual_engine.VisualEngine;
const ColorConfig = labelle.visual_engine.ColorConfig;
const Registry = ecs.Registry;
const Scene = scene_mod.Scene;
const SceneContext = scene_mod.SceneContext;

/// Configuration for window creation
pub const WindowConfig = struct {
    width: i32 = 800,
    height: i32 = 600,
    title: [:0]const u8 = "labelle Game",
    target_fps: i32 = 60,
    resizable: bool = false,
    hidden: bool = false,
};

/// Configuration for game initialization
pub const GameConfig = struct {
    window: WindowConfig = .{},
    clear_color: ColorConfig = .{ .r = 30, .g = 35, .b = 45 },
};

/// Scene lifecycle hooks
pub const SceneHooks = struct {
    onLoad: ?*const fn (*Game) void = null,
    onUnload: ?*const fn (*Game) void = null,
};

/// Internal scene data storage
const SceneEntry = struct {
    loader_fn: *const fn (*Game) anyerror!void,
    hooks: SceneHooks,
};

/// Frame callback type for custom game loop logic
pub const FrameCallback = *const fn (*Game, f32) void;

/// Game facade - main entry point for GUI-generated projects
pub const Game = struct {
    allocator: Allocator,
    visual_engine: VisualEngine,
    registry: Registry,

    // Scene management
    scenes: std.StringHashMap(SceneEntry),
    current_scene: ?Scene,
    current_scene_name: ?[]const u8,
    pending_scene_change: ?[]const u8,

    // Game state
    running: bool,

    /// Initialize a new game instance
    pub fn init(allocator: Allocator, config: GameConfig) !Game {
        var visual_engine = try VisualEngine.init(allocator, .{
            .window = .{
                .width = config.window.width,
                .height = config.window.height,
                .title = config.window.title,
                .target_fps = config.window.target_fps,
                .hidden = config.window.hidden,
            },
            .clear_color = config.clear_color,
        });
        errdefer visual_engine.deinit();

        var registry = Registry.init(allocator);
        errdefer registry.deinit();

        return Game{
            .allocator = allocator,
            .visual_engine = visual_engine,
            .registry = registry,
            .scenes = std.StringHashMap(SceneEntry).init(allocator),
            .current_scene = null,
            .current_scene_name = null,
            .pending_scene_change = null,
            .running = true,
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *Game) void {
        // Unload current scene if any
        if (self.current_scene) |*scene| {
            if (self.current_scene_name) |name| {
                if (self.scenes.get(name)) |entry| {
                    if (entry.hooks.onUnload) |onUnload| {
                        onUnload(self);
                    }
                }
            }
            scene.deinit();
        }

        self.scenes.deinit();
        self.registry.deinit();
        self.visual_engine.deinit();
    }

    /// Register a scene with the game
    /// The LoaderType must have a load(scene_data, SceneContext) function
    pub fn registerScene(
        self: *Game,
        comptime name: []const u8,
        comptime LoaderType: type,
        comptime scene_data: anytype,
        hooks: SceneHooks,
    ) !void {
        const loader_fn = struct {
            fn load(game: *Game) anyerror!void {
                const ctx = SceneContext.init(
                    &game.visual_engine,
                    &game.registry,
                    game.allocator,
                );
                game.current_scene = try LoaderType.load(scene_data, ctx);
            }
        }.load;

        try self.scenes.put(name, .{
            .loader_fn = loader_fn,
            .hooks = hooks,
        });
    }

    /// Register a scene without hooks (convenience method)
    pub fn registerSceneSimple(
        self: *Game,
        comptime name: []const u8,
        comptime LoaderType: type,
        comptime scene_data: anytype,
    ) !void {
        try self.registerScene(name, LoaderType, scene_data, .{});
    }

    /// Set the active scene immediately
    pub fn setScene(self: *Game, name: []const u8) !void {
        // Unload current scene
        if (self.current_scene) |*scene| {
            if (self.current_scene_name) |current_name| {
                if (self.scenes.get(current_name)) |entry| {
                    if (entry.hooks.onUnload) |onUnload| {
                        onUnload(self);
                    }
                }
            }
            scene.deinit();
            self.current_scene = null;
        }

        // Clear ECS registry for new scene
        self.registry.deinit();
        self.registry = Registry.init(self.allocator);

        // Load new scene
        const entry = self.scenes.get(name) orelse return error.SceneNotFound;
        try entry.loader_fn(self);
        self.current_scene_name = name;

        // Call onLoad hook
        if (entry.hooks.onLoad) |onLoad| {
            onLoad(self);
        }
    }

    /// Queue a scene change to happen at the end of the current frame
    /// This is safe to call from within scripts
    pub fn queueSceneChange(self: *Game, name: []const u8) void {
        self.pending_scene_change = name;
    }

    /// Get the name of the current scene
    pub fn getCurrentSceneName(self: *const Game) ?[]const u8 {
        return self.current_scene_name;
    }

    /// Stop the game loop
    pub fn quit(self: *Game) void {
        self.running = false;
    }

    /// Run the default game loop
    pub fn run(self: *Game) !void {
        try self.runWithCallback(null);
    }

    /// Run the game loop with an optional frame callback
    pub fn runWithCallback(self: *Game, callback: ?FrameCallback) !void {
        while (self.running and self.visual_engine.isRunning()) {
            const dt = self.visual_engine.getDeltaTime();

            // Update current scene
            if (self.current_scene) |*scene| {
                scene.update(dt);
            }

            // Call custom frame callback if provided
            if (callback) |cb| {
                cb(self, dt);
            }

            // Render
            self.visual_engine.beginFrame();
            self.visual_engine.tick(dt);
            self.visual_engine.endFrame();

            // Handle pending scene change
            if (self.pending_scene_change) |next_scene| {
                try self.setScene(next_scene);
                self.pending_scene_change = null;
            }
        }
    }

    /// Get access to the visual engine (for advanced use)
    pub fn getVisualEngine(self: *Game) *VisualEngine {
        return &self.visual_engine;
    }

    /// Get access to the ECS registry (for advanced use)
    pub fn getRegistry(self: *Game) *Registry {
        return &self.registry;
    }

    /// Get the current scene (for advanced use)
    pub fn getCurrentScene(self: *Game) ?*Scene {
        if (self.current_scene) |*scene| {
            return scene;
        }
        return null;
    }

    /// Get delta time from visual engine
    pub fn getDeltaTime(self: *Game) f32 {
        return self.visual_engine.getDeltaTime();
    }

    /// Take a screenshot
    pub fn takeScreenshot(self: *Game, filename: [:0]const u8) void {
        self.visual_engine.takeScreenshot(filename);
    }
};

test "Game compiles" {
    _ = Game;
}
