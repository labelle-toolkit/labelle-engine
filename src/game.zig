// Game facade - simplified API for GUI-generated projects
//
// Provides a high-level interface that encapsulates:
// - RetainedEngine initialization (new render pipeline)
// - RenderPipeline for ECS-to-graphics sync
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
//   // Create entities with Position + visual components
//   const entity = game.createEntity();
//   try game.addPosition(entity, .{ .x = 100, .y = 200 });
//   try game.addSprite(entity, .{ .texture = tex_id });
//
//   try game.run();

const std = @import("std");
const labelle = @import("labelle");
const ecs = @import("ecs");
const render_pipeline_mod = @import("render_pipeline.zig");

const Allocator = std.mem.Allocator;
const RetainedEngine = labelle.RetainedEngine;
const Registry = ecs.Registry;
const Entity = ecs.Entity;

// Re-export render pipeline types
pub const RenderPipeline = render_pipeline_mod.RenderPipeline;
pub const Position = render_pipeline_mod.Position;
pub const Sprite = render_pipeline_mod.Sprite;
pub const Shape = render_pipeline_mod.Shape;
pub const Text = render_pipeline_mod.Text;
pub const VisualType = render_pipeline_mod.VisualType;
pub const Color = render_pipeline_mod.Color;
pub const TextureId = render_pipeline_mod.TextureId;
pub const FontId = render_pipeline_mod.FontId;

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
    clear_color: Color = .{ .r = 30, .g = 35, .b = 45 },
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
    retained_engine: RetainedEngine,
    registry: Registry,
    pipeline: RenderPipeline,

    // Scene management
    scenes: std.StringHashMap(SceneEntry),
    current_scene_name: ?[]const u8,
    pending_scene_change: ?[]const u8,

    // Game state
    running: bool,

    /// Initialize a new game instance
    pub fn init(allocator: Allocator, config: GameConfig) !Game {
        var retained_engine = try RetainedEngine.init(allocator, .{
            .window = .{
                .width = config.window.width,
                .height = config.window.height,
                .title = config.window.title,
                .target_fps = config.window.target_fps,
                .hidden = config.window.hidden,
            },
            .clear_color = config.clear_color,
        });
        errdefer retained_engine.deinit();

        var registry = Registry.init(allocator);
        errdefer registry.deinit();

        var pipeline = RenderPipeline.init(allocator, &retained_engine);
        errdefer pipeline.deinit();

        // Build the Game struct. Note: pipeline.engine currently points to the
        // local `retained_engine` variable above, which will become invalid after
        // the struct is moved to the return value.
        var game = Game{
            .allocator = allocator,
            .retained_engine = retained_engine,
            .registry = registry,
            .pipeline = pipeline,
            .scenes = std.StringHashMap(SceneEntry).init(allocator),
            .current_scene_name = null,
            .pending_scene_change = null,
            .running = true,
        };

        // IMPORTANT: Fix pipeline.engine pointer after the struct move.
        // The pipeline was initialized with &retained_engine (a local variable).
        // After moving into the Game struct, we must update the pointer to reference
        // the new location (game.retained_engine). This is safe because:
        // 1. We update the pointer before returning
        // 2. The Game struct is returned by value and won't move again
        // 3. All subsequent access is through *Game pointers
        game.pipeline.engine = &game.retained_engine;

        return game;
    }

    /// Clean up all resources
    pub fn deinit(self: *Game) void {
        self.unloadCurrentScene();

        // Free owned strings
        if (self.current_scene_name) |name| {
            self.allocator.free(name);
        }
        if (self.pending_scene_change) |name| {
            self.allocator.free(name);
        }

        self.scenes.deinit();
        self.pipeline.deinit();
        self.registry.deinit();
        self.retained_engine.deinit();
    }

    /// Unload the current scene (helper to avoid duplication)
    fn unloadCurrentScene(self: *Game) void {
        if (self.current_scene_name) |name| {
            if (self.scenes.get(name)) |entry| {
                if (entry.hooks.onUnload) |onUnload| {
                    onUnload(self);
                }
            }
        }

        // Clear all tracked entities from pipeline and destroy their visuals
        self.pipeline.clear();
    }

    // ==================== Entity Management ====================

    /// Create a new entity
    pub fn createEntity(self: *Game) Entity {
        return self.registry.create();
    }

    /// Destroy an entity and its visual representation
    pub fn destroyEntity(self: *Game, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.destroy(entity);
    }

    /// Add Position component to an entity
    pub fn addPosition(self: *Game, entity: Entity, pos: Position) void {
        self.registry.add(entity, pos);
    }

    /// Set Position component (marks dirty for sync)
    pub fn setPosition(self: *Game, entity: Entity, pos: Position) void {
        if (self.registry.tryGet(Position, entity)) |p| {
            p.* = pos;
            self.pipeline.markPositionDirty(entity);
        }
    }

    /// Get Position component
    pub fn getPosition(self: *Game, entity: Entity) ?*Position {
        return self.registry.tryGet(Position, entity);
    }

    /// Add Sprite component and track for rendering
    pub fn addSprite(self: *Game, entity: Entity, sprite: Sprite) !void {
        self.registry.add(entity, sprite);
        try self.pipeline.trackEntity(entity, .sprite);
    }

    /// Add Shape component and track for rendering
    pub fn addShape(self: *Game, entity: Entity, shape: Shape) !void {
        self.registry.add(entity, shape);
        try self.pipeline.trackEntity(entity, .shape);
    }

    /// Add Text component and track for rendering
    pub fn addText(self: *Game, entity: Entity, text: Text) !void {
        self.registry.add(entity, text);
        try self.pipeline.trackEntity(entity, .text);
    }

    /// Remove Sprite component and stop tracking for rendering
    pub fn removeSprite(self: *Game, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Sprite, entity);
    }

    /// Remove Shape component and stop tracking for rendering
    pub fn removeShape(self: *Game, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Shape, entity);
    }

    /// Remove Text component and stop tracking for rendering
    pub fn removeText(self: *Game, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Text, entity);
    }

    /// Add a custom component to an entity
    pub fn addComponent(self: *Game, comptime T: type, entity: Entity, component: T) void {
        self.registry.add(entity, component);
    }

    /// Get a component from an entity
    pub fn getComponent(self: *Game, comptime T: type, entity: Entity) ?*T {
        return self.registry.tryGet(T, entity);
    }

    // ==================== Asset Loading ====================

    /// Load a texture and return its ID
    pub fn loadTexture(self: *Game, path: [:0]const u8) !TextureId {
        return self.retained_engine.loadTexture(path);
    }

    /// Load a texture atlas
    pub fn loadAtlas(self: *Game, name: []const u8, json_path: [:0]const u8, texture_path: [:0]const u8) !void {
        return self.retained_engine.loadAtlas(name, json_path, texture_path);
    }

    // ==================== Scene Management ====================

    /// Register a scene with the game
    pub fn registerScene(
        self: *Game,
        comptime name: []const u8,
        comptime loader_fn: fn (*Game) anyerror!void,
        hooks: SceneHooks,
    ) !void {
        const wrapper = struct {
            fn load(game: *Game) anyerror!void {
                return loader_fn(game);
            }
        }.load;

        try self.scenes.put(name, .{
            .loader_fn = wrapper,
            .hooks = hooks,
        });
    }

    /// Register a scene without hooks (convenience method)
    pub fn registerSceneSimple(
        self: *Game,
        comptime name: []const u8,
        comptime loader_fn: fn (*Game) anyerror!void,
    ) !void {
        try self.registerScene(name, loader_fn, .{});
    }

    /// Set the active scene immediately
    pub fn setScene(self: *Game, name: []const u8) !void {
        // Unload current scene
        self.unloadCurrentScene();

        // Free old scene name if owned
        if (self.current_scene_name) |old_name| {
            self.allocator.free(old_name);
            self.current_scene_name = null;
        }

        // Clear ECS registry for new scene
        self.registry.deinit();
        self.registry = Registry.init(self.allocator);

        // Reset pipeline
        self.pipeline.deinit();
        self.pipeline = RenderPipeline.init(self.allocator, &self.retained_engine);

        // Load new scene
        const entry = self.scenes.get(name) orelse return error.SceneNotFound;
        try entry.loader_fn(self);

        // Own the scene name by duplicating it
        self.current_scene_name = try self.allocator.dupe(u8, name);

        // Call onLoad hook
        if (entry.hooks.onLoad) |onLoad| {
            onLoad(self);
        }
    }

    /// Queue a scene change to happen at the end of the current frame
    /// This is safe to call from within scripts
    pub fn queueSceneChange(self: *Game, name: []const u8) void {
        // Free any existing pending change
        if (self.pending_scene_change) |old| {
            self.allocator.free(old);
        }
        // Own the name by duplicating it
        self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
    }

    /// Get the name of the current scene
    pub fn getCurrentSceneName(self: *const Game) ?[]const u8 {
        return self.current_scene_name;
    }

    /// Stop the game loop
    pub fn quit(self: *Game) void {
        self.running = false;
    }

    // ==================== Game Loop ====================

    /// Run the default game loop
    pub fn run(self: *Game) !void {
        try self.runWithCallback(null);
    }

    /// Run the game loop with an optional frame callback
    pub fn runWithCallback(self: *Game, callback: ?FrameCallback) !void {
        while (self.running and self.retained_engine.isRunning()) {
            const dt = self.retained_engine.getDeltaTime();

            // Call custom frame callback if provided
            if (callback) |cb| {
                cb(self, dt);
            }

            // Sync ECS state to RetainedEngine
            self.pipeline.sync(&self.registry);

            // Render
            self.retained_engine.beginFrame();
            self.retained_engine.render();
            self.retained_engine.endFrame();

            // Handle pending scene change
            if (self.pending_scene_change) |next_scene| {
                defer {
                    self.allocator.free(next_scene);
                    self.pending_scene_change = null;
                }
                try self.setScene(next_scene);
            }
        }
    }

    // ==================== Accessors ====================

    /// Get access to the retained engine (for advanced use)
    pub fn getRetainedEngine(self: *Game) *RetainedEngine {
        return &self.retained_engine;
    }

    /// Get access to the ECS registry (for advanced use)
    pub fn getRegistry(self: *Game) *Registry {
        return &self.registry;
    }

    /// Get access to the render pipeline (for advanced use)
    pub fn getPipeline(self: *Game) *RenderPipeline {
        return &self.pipeline;
    }

    /// Get delta time from retained engine
    pub fn getDeltaTime(self: *Game) f32 {
        return self.retained_engine.getDeltaTime();
    }

    /// Check if the game is still running
    pub fn isRunning(self: *const Game) bool {
        return self.running and self.retained_engine.isRunning();
    }
};

test "Game compiles" {
    _ = Game;
}
