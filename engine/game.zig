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
const input_mod = @import("input");
const audio_mod = @import("audio");
const render_pipeline_mod = @import("../render/src/pipeline.zig");
const hooks_mod = @import("../hooks/mod.zig");

const Allocator = std.mem.Allocator;
// Use the backend-aware RetainedEngine from render_pipeline
const RetainedEngine = render_pipeline_mod.RetainedEngine;
const Registry = ecs.Registry;
const Entity = ecs.Entity;
const Input = input_mod.Input;
const Audio = audio_mod.Audio;

// Entity <-> u64 conversion for hook payloads (matches src/scene.zig helpers)
// We keep this local to avoid importing scene.zig (and risking cycles).
const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));
comptime {
    if (@sizeOf(Entity) > @sizeOf(u64)) {
        @compileError("Entity must fit in u64 for hook payloads");
    }
}
fn entityToU64(entity: Entity) u64 {
    return @as(u64, @intCast(@as(EntityBits, @bitCast(entity))));
}

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

/// Screen size dimensions
pub const ScreenSize = struct {
    width: i32,
    height: i32,
};

/// Game facade - main entry point for GUI-generated projects.
/// Use `GameWith(MyHooks)` to enable lifecycle hooks, or just `Game` for no hooks.
pub fn GameWith(comptime Hooks: type) type {
    // Determine if hooks are enabled (Hooks is not void and not empty struct)
    const hooks_enabled = comptime blk: {
        if (Hooks == void) break :blk false;
        const info = @typeInfo(Hooks);
        if (info == .@"struct" and info.@"struct".decls.len == 0) break :blk false;
        break :blk true;
    };

    return struct {
        const Self = @This();

        /// The hook dispatcher type for this game instance.
        /// If Hooks already has an 'emit' method (e.g., from MergeHooks), use it directly.
        /// Otherwise, wrap it with EngineHookDispatcher.
        pub const HookDispatcher = if (hooks_enabled)
            if (@hasDecl(Hooks, "emit"))
                Hooks // Already a dispatcher (e.g., from MergeHooks)
            else
                hooks_mod.EngineHookDispatcher(Hooks)
        else
            hooks_mod.EmptyEngineDispatcher;

        /// Scene lifecycle hooks
        pub const SceneHooks = struct {
            onLoad: ?*const fn (*Self) void = null,
            onUnload: ?*const fn (*Self) void = null,
        };

        /// Internal scene data storage
        const SceneEntry = struct {
            loader_fn: *const fn (*Self) anyerror!void,
            hooks: SceneHooks,
        };

        /// Frame callback type for custom game loop logic
        pub const FrameCallback = *const fn (*Self, f32) void;

        allocator: Allocator,
        retained_engine: RetainedEngine,
        registry: Registry,
        pipeline: RenderPipeline,
        input: Input,
        audio: Audio,

        // Scene management
        scenes: std.StringHashMap(SceneEntry),
        current_scene_name: ?[]const u8,
        pending_scene_change: ?[]const u8,

        // Game state
        running: bool,

        // Frame tracking (for hooks)
        frame_number: u64 = 0,

        /// Emit a hook event. No-op if hooks are disabled.
        inline fn emitHook(payload: hooks_mod.HookPayload) void {
            if (hooks_enabled) {
                HookDispatcher.emit(payload);
            }
        }

        /// Initialize a new game instance
        pub fn init(allocator: Allocator, config: GameConfig) !Self {
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

        const input = Input.init();
        const audio = Audio.init();

        // Build the struct. Note: pipeline.engine currently points to the
        // local `retained_engine` variable above, which will become invalid after
        // the struct is moved to the caller's stack.
        const game = Self{
            .allocator = allocator,
            .retained_engine = retained_engine,
            .registry = registry,
            .pipeline = pipeline,
            .input = input,
            .audio = audio,
            .scenes = std.StringHashMap(SceneEntry).init(allocator),
            .current_scene_name = null,
            .pending_scene_change = null,
            .running = true,
        };

        // Emit game_init hook with allocator for early subsystem initialization
        emitHook(.{ .game_init = .{ .allocator = allocator } });

        return game;
    }

    /// Fix internal pointers after the Game struct has been moved.
    /// MUST be called immediately after init() when the struct is in its final location.
    /// Example:
    ///   var game = try Game.init(allocator, config);
    ///   game.fixPointers();
    pub fn fixPointers(self: *Self) void {
        self.pipeline.engine = &self.retained_engine;

        // Set the game pointer for component callbacks to access
        ecs.setGamePtr(self);

        // Set the global pipeline pointer for render component callbacks
        render_pipeline_mod.setGlobalPipeline(&self.pipeline);
    }

        /// Clean up all resources
        pub fn deinit(self: *Self) void {
            // Emit game_deinit hook before cleanup
            emitHook(.{ .game_deinit = {} });

            // Clear game pointer to prevent use-after-free in component callbacks
            ecs.setGamePtr(null);

            // Clear global pipeline pointer
            render_pipeline_mod.setGlobalPipeline(null);

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
        self.input.deinit();
        self.audio.deinit();
        self.retained_engine.deinit();
    }

        /// Unload the current scene (helper to avoid duplication)
        fn unloadCurrentScene(self: *Self) void {
            if (self.current_scene_name) |name| {
                // Emit scene_unload hook
                emitHook(.{ .scene_unload = .{ .name = name } });

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
    pub fn createEntity(self: *Self) Entity {
        const entity = self.registry.create();
        // Emit entity_created hook (prefab_name is unknown at this layer)
        emitHook(.{ .entity_created = .{ .entity_id = entityToU64(entity), .prefab_name = null } });
        return entity;
    }

    /// Destroy an entity and its visual representation
    pub fn destroyEntity(self: *Self, entity: Entity) void {
        // Emit entity_destroyed hook before destruction
        emitHook(.{ .entity_destroyed = .{ .entity_id = entityToU64(entity), .prefab_name = null } });
        self.pipeline.untrackEntity(entity);
        self.registry.destroy(entity);
    }

    /// Add Position component to an entity
    pub fn addPosition(self: *Self, entity: Entity, pos: Position) void {
        self.registry.add(entity, pos);
    }

    /// Set Position component (marks dirty for sync)
    pub fn setPosition(self: *Self, entity: Entity, pos: Position) void {
        if (self.registry.tryGet(Position, entity)) |p| {
            p.* = pos;
            self.pipeline.markPositionDirty(entity);
        }
    }

    /// Set Position using x, y coordinates directly (marks dirty for sync)
    pub fn setPositionXY(self: *Self, entity: Entity, x: f32, y: f32) void {
        if (self.registry.tryGet(Position, entity)) |p| {
            p.x = x;
            p.y = y;
            self.pipeline.markPositionDirty(entity);
        }
    }

    /// Move Position by delta values (marks dirty for sync)
    pub fn movePosition(self: *Self, entity: Entity, dx: f32, dy: f32) void {
        if (self.registry.tryGet(Position, entity)) |p| {
            p.x += dx;
            p.y += dy;
            self.pipeline.markPositionDirty(entity);
        }
    }

    /// Get Position component
    pub fn getPosition(self: *Self, entity: Entity) ?*Position {
        return self.registry.tryGet(Position, entity);
    }

    /// Set z_index on entity's visual component (Sprite, Shape, or Text)
    /// Marks visual dirty for sync to graphics
    pub fn setZIndex(self: *Self, entity: Entity, z_index: u8) void {
        var updated = false;

        // Try Sprite
        if (self.registry.tryGet(Sprite, entity)) |sprite| {
            sprite.z_index = z_index;
            updated = true;
        }

        // Try Shape
        if (self.registry.tryGet(Shape, entity)) |shape| {
            shape.z_index = z_index;
            updated = true;
        }

        // Try Text
        if (self.registry.tryGet(Text, entity)) |text| {
            text.z_index = z_index;
            updated = true;
        }

        if (updated) {
            self.pipeline.markVisualDirty(entity);
        }
    }

    /// Add Sprite component and track for rendering
    pub fn addSprite(self: *Self, entity: Entity, sprite: Sprite) !void {
        self.registry.add(entity, sprite);
        try self.pipeline.trackEntity(entity, .sprite);
    }

    /// Add Shape component and track for rendering
    pub fn addShape(self: *Self, entity: Entity, shape: Shape) !void {
        self.registry.add(entity, shape);
        try self.pipeline.trackEntity(entity, .shape);
    }

    /// Add Text component and track for rendering
    pub fn addText(self: *Self, entity: Entity, text: Text) !void {
        self.registry.add(entity, text);
        try self.pipeline.trackEntity(entity, .text);
    }

    /// Remove Sprite component and stop tracking for rendering
    pub fn removeSprite(self: *Self, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Sprite, entity);
    }

    /// Remove Shape component and stop tracking for rendering
    pub fn removeShape(self: *Self, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Shape, entity);
    }

    /// Remove Text component and stop tracking for rendering
    pub fn removeText(self: *Self, entity: Entity) void {
        self.pipeline.untrackEntity(entity);
        self.registry.remove(Text, entity);
    }

    /// Add a custom component to an entity
    pub fn addComponent(self: *Self, comptime T: type, entity: Entity, component: T) void {
        self.registry.add(entity, component);
    }

    /// Set/update a custom component on an entity (triggers component `onSet` if defined).
    /// If the entity doesn't have the component yet, this will add it.
    pub fn setComponent(self: *Self, entity: Entity, component: anytype) void {
        self.registry.setComponent(entity, component);
    }

    /// Get a component from an entity
    pub fn getComponent(self: *Self, comptime T: type, entity: Entity) ?*T {
        return self.registry.tryGet(T, entity);
    }

    // ==================== Asset Loading ====================

    /// Load a texture and return its ID
    pub fn loadTexture(self: *Self, path: [:0]const u8) !TextureId {
        return self.retained_engine.loadTexture(path);
    }

    /// Load a texture atlas
    pub fn loadAtlas(self: *Self, name: []const u8, json_path: [:0]const u8, texture_path: [:0]const u8) !void {
        return self.retained_engine.loadAtlas(name, json_path, texture_path);
    }

    // ==================== Scene Management ====================

    /// Register a scene with the game
    pub fn registerScene(
        self: *Self,
        comptime name: []const u8,
        comptime loader_fn: fn (*Self) anyerror!void,
        hooks: SceneHooks,
    ) !void {
        const wrapper = struct {
            fn load(game: *Self) anyerror!void {
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
        self: *Self,
        comptime name: []const u8,
        comptime loader_fn: fn (*Self) anyerror!void,
    ) !void {
        try self.registerScene(name, loader_fn, .{});
    }

    /// Set the active scene immediately
    pub fn setScene(self: *Self, name: []const u8) !void {
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

        // Look up scene entry
        const entry = self.scenes.get(name) orelse return error.SceneNotFound;

        // Emit scene_before_load hook before entities are created
        emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });

        // Load new scene (creates entities, triggers component callbacks)
        try entry.loader_fn(self);

        // Own the scene name by duplicating it
        self.current_scene_name = try self.allocator.dupe(u8, name);

        // Call onLoad hook
        if (entry.hooks.onLoad) |onLoad| {
            onLoad(self);
        }

        // Emit scene_load hook
        emitHook(.{ .scene_load = .{ .name = name } });
    }

    /// Queue a scene change to happen at the end of the current frame
    /// This is safe to call from within scripts
    pub fn queueSceneChange(self: *Self, name: []const u8) void {
        // Free any existing pending change
        if (self.pending_scene_change) |old| {
            self.allocator.free(old);
        }
        // Own the name by duplicating it
        self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
    }

    /// Get the name of the current scene
    pub fn getCurrentSceneName(self: *const Self) ?[]const u8 {
        return self.current_scene_name;
    }

    /// Stop the game loop
    pub fn quit(self: *Self) void {
        self.running = false;
    }

    // ==================== Game Loop ====================

    /// Run the default game loop.
    ///
    /// Note: This polling-style game loop works with raylib and SDL backends.
    /// For sokol backend, use sokol's callback-based event loop directly:
    /// - Register a sokol event callback that calls `game.getInput().processEvent(event)`
    /// - In your frame callback, call `game.getInput().beginFrame()` at the start
    pub fn run(self: *Self) !void {
        try self.runWithCallback(null);
    }

    /// Run the game loop with an optional frame callback.
    ///
    /// Note: This polling-style game loop works with raylib and SDL backends.
    /// For sokol backend, you must use sokol's callback-based architecture instead.
        pub fn runWithCallback(self: *Self, callback: ?FrameCallback) !void {
            while (self.running and self.retained_engine.isRunning()) {
                const dt = self.retained_engine.getDeltaTime();

                // Emit frame_start hook
                emitHook(.{ .frame_start = .{ .frame_number = self.frame_number, .dt = dt } });

                // Begin input frame (clears per-frame state)
                self.input.beginFrame();

                // Call custom frame callback if provided
                if (callback) |cb| {
                    cb(self, dt);
                }

                // Sync ECS state to RetainedEngine
                self.pipeline.sync(&self.registry);

                // Update audio (for music streaming)
                self.audio.update();

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

                // Emit frame_end hook
                emitHook(.{ .frame_end = .{ .frame_number = self.frame_number, .dt = dt } });

                self.frame_number += 1;
            }
        }

    // ==================== Camera ====================

    /// Set the primary camera position
    pub fn setCameraPosition(self: *Self, x: f32, y: f32) void {
        self.retained_engine.setCameraPosition(x, y);
    }

    /// Set the primary camera zoom level
    pub fn setCameraZoom(self: *Self, zoom: f32) void {
        self.retained_engine.setZoom(zoom);
    }

    /// Get the primary camera (for advanced use)
    pub fn getCamera(self: *Self) *labelle.Camera {
        return self.retained_engine.getCamera();
    }

    // ==================== Multi-Camera ====================

    /// Get a camera by index (0-3)
    pub fn getCameraAt(self: *Self, index: u2) *labelle.Camera {
        return self.retained_engine.getCameraAt(index);
    }

    /// Get the camera manager (for advanced multi-camera control)
    pub fn getCameraManager(self: *Self) *labelle.CameraManager {
        return self.retained_engine.getCameraManager();
    }

    /// Set up split-screen with a predefined layout
    pub fn setupSplitScreen(self: *Self, layout: labelle.SplitScreenLayout) void {
        self.retained_engine.setupSplitScreen(layout);
    }

    /// Disable multi-camera mode (return to single camera)
    pub fn disableMultiCamera(self: *Self) void {
        self.retained_engine.disableMultiCamera();
    }

    /// Check if multi-camera mode is enabled
    pub fn isMultiCameraEnabled(self: *const Self) bool {
        return self.retained_engine.isMultiCameraEnabled();
    }

    /// Set which cameras are active (bitmask: bit 0 = camera 0, etc.)
    pub fn setActiveCameras(self: *Self, mask: u4) void {
        self.retained_engine.setActiveCameras(mask);
    }

    // ==================== Accessors ====================

    /// Get access to the retained engine (for advanced use)
    pub fn getRetainedEngine(self: *Self) *RetainedEngine {
        return &self.retained_engine;
    }

    /// Get access to the ECS registry (for advanced use)
    pub fn getRegistry(self: *Self) *Registry {
        return &self.registry;
    }

    /// Get access to the render pipeline (for advanced use)
    pub fn getPipeline(self: *Self) *RenderPipeline {
        return &self.pipeline;
    }

    /// Get access to the input system
    pub fn getInput(self: *Self) *Input {
        return &self.input;
    }

    /// Get access to the audio system
    pub fn getAudio(self: *Self) *Audio {
        return &self.audio;
    }

    /// Get delta time from retained engine
    pub fn getDeltaTime(self: *Self) f32 {
        return self.retained_engine.getDeltaTime();
    }

    /// Check if the game is still running
    pub fn isRunning(self: *const Self) bool {
        return self.running and self.retained_engine.isRunning();
    }

    // ==================== Fullscreen ====================

    /// Toggle between fullscreen and windowed mode
    pub fn toggleFullscreen(self: *Self) void {
        self.retained_engine.toggleFullscreen();
    }

    /// Set fullscreen mode explicitly
    pub fn setFullscreen(self: *Self, fullscreen: bool) void {
        self.retained_engine.setFullscreen(fullscreen);
    }

    /// Check if window is currently in fullscreen mode
    pub fn isFullscreen(self: *const Self) bool {
        return self.retained_engine.isFullscreen();
    }

    // ==================== Screen Size ====================

    /// Check if screen size changed since last frame (fullscreen toggle, window resize)
    pub fn screenSizeChanged(self: *const Self) bool {
        return self.retained_engine.screenSizeChanged();
    }

    /// Get current screen/window size
    pub fn getScreenSize(self: *const Self) ScreenSize {
        const size = self.retained_engine.getWindowSize();
        return .{ .width = size.w, .height = size.h };
    }

    // ==================== Screenshot ====================

    /// Take a screenshot of the current frame and save to file.
    /// The filename should include the extension (e.g., "screenshot.png").
    /// Note: Call this after render() but before endFrame() for best results.
    pub fn takeScreenshot(self: *const Self, filename: [*:0]const u8) void {
        self.retained_engine.takeScreenshot(filename);
    }
    };
}

/// Default Game type with hooks disabled for backwards compatibility.
/// Use `GameWith(MyHooks)` to enable lifecycle hooks.
pub const Game = GameWith(void);
