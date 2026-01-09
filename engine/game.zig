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
const gui_mod = @import("gui");
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
pub const ShapeType = render_pipeline_mod.ShapeType;
pub const GfxPosition = render_pipeline_mod.GfxPosition;
pub const Icon = render_pipeline_mod.Icon;
pub const GizmoVisibility = render_pipeline_mod.GizmoVisibility;
pub const BoundingBox = render_pipeline_mod.BoundingBox;

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

/// Max selectable entities for SparseSet allocation.
/// 10k entities uses ~40KB memory and covers most game scenarios.
const max_selectable_entities: usize = 10_000;

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

        /// Standalone gizmo that persists until cleared.
        /// Used for runtime gizmo drawing without creating entities.
        pub const StandaloneGizmo = struct {
            shape: labelle.retained_engine.Shape,
            x: f32,
            y: f32,
            color: labelle.retained_engine.Color,
            group: []const u8 = "",
        };

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

        // Deferred screenshot request (taken after render, before endFrame)
        pending_screenshot_filename: ?[:0]const u8 = null,

        // Gizmos visibility (debug-only visualization)
        gizmos_enabled: bool = true,

        // Standalone gizmos (not bound to entities)
        standalone_gizmos: std.ArrayList(StandaloneGizmo),

        // Entity selection tracking (for selected-only gizmos)
        // Uses DynamicBitSet for O(1) bit operations - minimal memory (~1.25KB for 10k entities)
        selected_entities: std.DynamicBitSet,

        // GUI state
        gui_enabled: bool = true,
        gui: gui_mod.Gui,

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

            // Initialize collections
            // ArrayList uses .empty in Zig 0.15, allocator passed to methods
            const standalone_gizmos_list = std.ArrayList(StandaloneGizmo).empty;
            const selected_entities_bitset = try std.DynamicBitSet.initEmpty(allocator, max_selectable_entities);

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
                .standalone_gizmos = standalone_gizmos_list,
                .selected_entities = selected_entities_bitset,
                .gui = gui_mod.Gui.init(),
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

            // Fix GUI internal pointers (microui has self-referential pointers)
            self.gui.fixPointers();
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
            if (self.pending_screenshot_filename) |filename| {
                self.allocator.free(filename);
            }

            self.scenes.deinit();
            self.standalone_gizmos.deinit(self.allocator);
            self.selected_entities.deinit();
            self.gui.deinit();
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

            // Clear entity selections (prevents stale references to destroyed entities)
            self.selected_entities.setRangeValue(.{ .start = 0, .end = self.selected_entities.capacity() }, false);

            // Clear standalone gizmos
            self.standalone_gizmos.clearRetainingCapacity();
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

            // Apply current gizmo visibility state to newly created gizmos
            self.updateGizmoVisibility();
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

                // Process deferred screenshot (after render, before endFrame)
                self.processPendingScreenshot();

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

        // ==================== Gizmos ====================

        /// Enable or disable gizmo rendering.
        /// Gizmos are debug-only visualizations that are stripped in release builds.
        /// When disabled, gizmo entities are hidden but not destroyed.
        pub fn setGizmosEnabled(self: *Self, enabled: bool) void {
            if (self.gizmos_enabled == enabled) return;
            self.gizmos_enabled = enabled;
            self.updateGizmoVisibility();
        }

        /// Check if gizmos are currently enabled.
        pub fn areGizmosEnabled(self: *const Self) bool {
            return self.gizmos_enabled;
        }

        // ==================== Entity Selection ====================

        /// Select an entity (for selected-only gizmo visibility).
        pub fn selectEntity(self: *Self, entity: Entity) void {
            const idx = entityToU64(entity);
            if (idx < max_selectable_entities) {
                self.selected_entities.set(@intCast(idx));
                self.updateGizmoVisibility();
            }
        }

        /// Deselect an entity.
        pub fn deselectEntity(self: *Self, entity: Entity) void {
            const idx = entityToU64(entity);
            if (idx < max_selectable_entities) {
                self.selected_entities.unset(@intCast(idx));
                self.updateGizmoVisibility();
            }
        }

        /// Clear all entity selections.
        pub fn clearSelection(self: *Self) void {
            self.selected_entities.setRangeValue(.{ .start = 0, .end = self.selected_entities.capacity() }, false);
            self.updateGizmoVisibility();
        }

        /// Check if an entity is selected.
        pub fn isEntitySelected(self: *const Self, entity: Entity) bool {
            const idx = entityToU64(entity);
            if (idx >= max_selectable_entities) return false;
            return self.selected_entities.isSet(@intCast(idx));
        }

        /// Update visibility of all gizmos based on their visibility mode and selection state.
        fn updateGizmoVisibility(self: *Self) void {
            const Gizmo = render_pipeline_mod.Gizmo;

            var view = self.registry.view(.{Gizmo});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                if (self.registry.tryGet(Gizmo, entity)) |gizmo| {
                    const should_show = switch (gizmo.visibility) {
                        .always => self.gizmos_enabled,
                        .selected_only => self.gizmos_enabled and
                            (gizmo.parent_entity != null and self.isEntitySelected(gizmo.parent_entity.?)),
                        .never => false,
                    };
                    self.setGizmoEntityVisible(entity, should_show);
                }
            }
        }

        /// Set visibility of a gizmo entity's visual components.
        fn setGizmoEntityVisible(self: *Self, entity: Entity, visible: bool) void {
            var changed = false;
            // Update visibility for all visual component types
            const visual_components = .{ Sprite, Shape, Text, Icon };
            inline for (visual_components) |ComponentType| {
                if (self.registry.tryGet(ComponentType, entity)) |comp| {
                    var updated = comp.*;
                    if (updated.visible != visible) {
                        updated.visible = visible;
                        self.registry.add(entity, updated);
                        changed = true;
                    }
                }
            }
            // Mark dirty so render pipeline syncs the change
            if (changed) {
                self.pipeline.markVisualDirty(entity);
            }
        }

        // ==================== Standalone Gizmos ====================

        /// Shape primitive union type (circle, rectangle, line, arrow, ray, etc.)
        /// from labelle-gfx visuals module. Used for standalone gizmo drawing.
        pub const GizmoShape = labelle.retained_engine.Shape;

        /// Draw a standalone gizmo (not bound to any entity).
        /// Gizmo persists until clearGizmos() is called.
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawGizmo(self: *Self, shape: GizmoShape, x: f32, y: f32, color: Color) void {
            if (@import("builtin").mode != .Debug) return;
            if (!self.gizmos_enabled) return;

            self.standalone_gizmos.append(self.allocator, .{
                .shape = shape,
                .x = x,
                .y = y,
                .color = color,
            }) catch return;
        }

        /// Draw an arrow gizmo from point (x1, y1) to point (x2, y2).
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawArrow(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
            self.drawGizmo(.{ .arrow = .{
                .delta = .{ .x = x2 - x1, .y = y2 - y1 },
            } }, x1, y1, color);
        }

        /// Draw a ray gizmo from origin in direction for given length.
        /// Direction should be normalized for predictable results.
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawRay(self: *Self, x: f32, y: f32, dir_x: f32, dir_y: f32, length: f32, color: Color) void {
            self.drawGizmo(.{ .ray = .{
                .direction = .{ .x = dir_x, .y = dir_y },
                .length = length,
            } }, x, y, color);
        }

        /// Draw a line gizmo from point (x1, y1) to point (x2, y2).
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
            self.drawGizmo(.{ .line = .{
                .end = .{ .x = x2 - x1, .y = y2 - y1 },
            } }, x1, y1, color);
        }

        /// Draw a circle gizmo at position with given radius.
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawCircle(self: *Self, x: f32, y: f32, radius: f32, color: Color) void {
            self.drawGizmo(.{ .circle = .{ .radius = radius } }, x, y, color);
        }

        /// Draw a rectangle gizmo at position with given dimensions.
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawRect(self: *Self, x: f32, y: f32, width: f32, height: f32, color: Color) void {
            self.drawGizmo(.{ .rectangle = .{
                .width = width,
                .height = height,
            } }, x, y, color);
        }

        /// Clear all standalone gizmos.
        pub fn clearGizmos(self: *Self) void {
            self.standalone_gizmos.clearRetainingCapacity();
        }

        /// Clear standalone gizmos in a specific group.
        /// Uses O(n) single-pass filter instead of O(n²) orderedRemove loop.
        pub fn clearGizmoGroup(self: *Self, group: []const u8) void {
            var write_idx: usize = 0;
            for (self.standalone_gizmos.items) |item| {
                if (!std.mem.eql(u8, item.group, group)) {
                    self.standalone_gizmos.items[write_idx] = item;
                    write_idx += 1;
                }
            }
            self.standalone_gizmos.shrinkRetainingCapacity(write_idx);
        }

        /// Render standalone gizmos.
        /// Call this after re.render() but before re.endFrame() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.renderStandaloneGizmos();  // Draw gizmos on top
        /// re.endFrame();
        /// ```
        /// No-op in release builds or when gizmos are disabled.
        pub fn renderStandaloneGizmos(self: *Self) void {
            if (@import("builtin").mode != .Debug) return;
            if (!self.gizmos_enabled) return;

            for (self.standalone_gizmos.items) |gizmo| {
                self.retained_engine.drawShape(gizmo.shape, .{ .x = gizmo.x, .y = gizmo.y }, gizmo.color);
            }
        }

        // ==================== Visual Bounds ====================

        /// Visual bounds (width and height) of an entity.
        pub const VisualBounds = struct {
            width: f32,
            height: f32,
        };

        /// Get the visual bounds (width, height) of an entity based on its visual component.
        /// Returns null if the entity has no visual component or dimensions cannot be determined.
        ///
        /// For Shape components: calculates bounds from shape definition.
        /// For Sprite components: looks up sprite dimensions from texture manager.
        pub fn getEntityVisualBounds(self: *Self, entity: Entity) ?VisualBounds {
            // Try Shape first (dimensions are directly available)
            if (self.registry.tryGet(Shape, entity)) |shape| {
                return getShapeBounds(shape.shape);
            }

            // Try Sprite (need to look up from texture manager)
            if (self.registry.tryGet(Sprite, entity)) |sprite| {
                return self.getSpriteBounds(sprite);
            }

            return null;
        }

        /// Get bounds from a Shape definition.
        fn getShapeBounds(shape: ShapeType) ?VisualBounds {
            return switch (shape) {
                .circle => |c| .{ .width = c.radius * 2, .height = c.radius * 2 },
                .rectangle => |r| .{ .width = r.width, .height = r.height },
                .line => |l| .{
                    .width = @abs(l.end.x) + l.thickness,
                    .height = @abs(l.end.y) + l.thickness,
                },
                .triangle => |t| .{
                    .width = @max(@max(0, t.p2.x), t.p3.x) - @min(@min(0, t.p2.x), t.p3.x),
                    .height = @max(@max(0, t.p2.y), t.p3.y) - @min(@min(0, t.p2.y), t.p3.y),
                },
                .polygon => |p| .{
                    .width = p.radius * 2,
                    .height = p.radius * 2,
                },
                .arrow => |a| .{
                    .width = @abs(a.delta.x) + a.head_size,
                    .height = @abs(a.delta.y) + a.head_size,
                },
                .ray => |r| .{
                    .width = @abs(r.direction.x * r.length) + r.thickness,
                    .height = @abs(r.direction.y * r.length) + r.thickness,
                },
            };
        }

        /// Get bounds from a Sprite by looking up dimensions from texture manager.
        fn getSpriteBounds(self: *Self, sprite: *const Sprite) ?VisualBounds {
            const texture_manager = self.retained_engine.getTextureManager();
            if (texture_manager.findSprite(sprite.name)) |result| {
                const width: f32 = @floatFromInt(result.sprite.getWidth());
                const height: f32 = @floatFromInt(result.sprite.getHeight());
                return .{
                    .width = width * sprite.scale,
                    .height = height * sprite.scale,
                };
            }
            return null;
        }

        // ==================== GUI ====================

        /// Enable or disable GUI rendering.
        pub fn setGuiEnabled(self: *Self, enabled: bool) void {
            self.gui_enabled = enabled;
        }

        /// Check if GUI is currently enabled.
        pub fn isGuiEnabled(self: *const Self) bool {
            return self.gui_enabled;
        }

        /// Render GUI from a ViewRegistry.
        /// Call this after re.render() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.renderGui(Views, Scripts);
        /// re.endFrame();
        /// ```
        pub fn renderGui(self: *Self, comptime Views: type, comptime Scripts: type, comptime view_names: []const []const u8) void {
            if (!self.gui_enabled) return;

            self.gui.beginFrame();

            inline for (view_names) |view_name| {
                if (Views.has(view_name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElements(view_def.elements, Scripts);
                }
            }

            self.gui.endFrame();
        }

        /// Render a single GUI view by name.
        pub fn renderGuiView(self: *Self, comptime Views: type, comptime Scripts: type, comptime view_name: []const u8) void {
            if (!self.gui_enabled) return;
            if (!Views.has(view_name)) return;

            self.gui.beginFrame();
            const view_def = Views.get(view_name);
            self.renderGuiElements(view_def.elements, Scripts);
            self.gui.endFrame();
        }

        /// Internal: Render a list of GUI elements.
        fn renderGuiElements(self: *Self, elements: []const gui_mod.GuiElement, comptime Scripts: type) void {
            for (elements) |element| {
                self.renderGuiElement(element, Scripts);
            }
        }

        /// Internal: Render a single GUI element.
        fn renderGuiElement(self: *Self, element: gui_mod.GuiElement, comptime Scripts: type) void {
            // Check element visibility before rendering
            if (!element.isVisible()) return;

            switch (element) {
                .Label => |lbl| self.gui.label(lbl),
                .Button => |btn| {
                    if (self.gui.button(btn)) {
                        // Button was clicked - call script callback if defined
                        if (btn.on_click) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| self.gui.progressBar(bar),
                .Panel => |panel| {
                    self.gui.beginPanel(panel);
                    self.renderGuiElements(panel.children, Scripts);
                    self.gui.endPanel();
                },
                .Image => |img| self.gui.image(img),
                .Checkbox => |cb| {
                    if (self.gui.checkbox(cb)) {
                        // Checkbox was toggled - call script callback if defined
                        if (cb.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    const new_value = self.gui.slider(sl);
                    if (new_value != sl.value) {
                        // Slider value changed - call script callback if defined
                        if (sl.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }

        /// Internal: Invoke a GUI callback by name from the Scripts registry.
        fn invokeGuiCallback(self: *Self, comptime Scripts: type, callback_name: []const u8) void {
            // Scripts registry is comptime, so we can't dynamically lookup by runtime string.
            // For now, callbacks are just logged. A full implementation would require
            // a different approach (e.g., callback function pointers in elements).
            _ = self;
            _ = Scripts;
            std.log.debug("GUI callback: {s}", .{callback_name});
        }

        /// Render GUI views associated with a scene.
        ///
        /// Renders all views specified in the scene's .gui_views field.
        /// Call this after re.render() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.renderSceneGui(&scene, Views, Scripts);
        /// re.endFrame();
        /// ```
        pub fn renderSceneGui(self: *Self, scene: anytype, comptime Views: type, comptime Scripts: type) void {
            if (!self.gui_enabled) return;

            // Check if scene has gui_view_names field
            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            self.gui.beginFrame();

            // For each view name in the scene, check if it exists in Views registry
            for (view_names) |active_name| {
                self.renderViewByName(Views, Scripts, active_name);
            }

            self.gui.endFrame();
        }

        /// Internal: Render a view by runtime name using comptime Views lookup.
        fn renderViewByName(self: *Self, comptime Views: type, comptime Scripts: type, name: []const u8) void {
            // Use comptime iteration over Views to match the runtime name
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElements(view_def.elements, Scripts);
                    return;
                }
            }
        }

        /// Render GUI views associated with a scene, with runtime visibility overrides.
        ///
        /// Same as renderSceneGui but allows dynamic element visibility control.
        /// Call this after re.render() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.renderSceneGuiWithVisibility(&scene, Views, Scripts, &visibility_state);
        /// re.endFrame();
        /// ```
        pub fn renderSceneGuiWithVisibility(
            self: *Self,
            scene: anytype,
            comptime Views: type,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            if (!self.gui_enabled) return;

            // Check if scene has gui_view_names field
            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            self.gui.beginFrame();

            // For each view name in the scene, check if it exists in Views registry
            for (view_names) |active_name| {
                self.renderViewByNameWithVisibility(Views, Scripts, active_name, visibility_state);
            }

            self.gui.endFrame();
        }

        /// Internal: Render a view by runtime name with visibility overrides.
        fn renderViewByNameWithVisibility(
            self: *Self,
            comptime Views: type,
            comptime Scripts: type,
            name: []const u8,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            // Use comptime iteration over Views to match the runtime name
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElementsWithVisibility(view_def.elements, Scripts, visibility_state);
                    return;
                }
            }
        }

        /// Internal: Render GUI elements with visibility overrides.
        fn renderGuiElementsWithVisibility(
            self: *Self,
            elements: []const gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            for (elements) |element| {
                self.renderGuiElementWithVisibility(element, Scripts, visibility_state);
            }
        }

        /// Internal: Render a single GUI element with visibility override.
        fn renderGuiElementWithVisibility(
            self: *Self,
            element: gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            // Check visibility: use override if element has an ID, otherwise use default
            const element_id = element.getId();
            const is_visible = if (element_id.len > 0)
                visibility_state.isVisible(element_id, element.isVisible())
            else
                element.isVisible();

            if (!is_visible) return;

            switch (element) {
                .Label => |lbl| self.gui.label(lbl),
                .Button => |btn| {
                    if (self.gui.button(btn)) {
                        if (btn.on_click) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| self.gui.progressBar(bar),
                .Panel => |panel| {
                    self.gui.beginPanel(panel);
                    self.renderGuiElementsWithVisibility(panel.children, Scripts, visibility_state);
                    self.gui.endPanel();
                },
                .Image => |img| self.gui.image(img),
                .Checkbox => |cb| {
                    if (self.gui.checkbox(cb)) {
                        if (cb.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    const new_value = self.gui.slider(sl);
                    if (new_value != sl.value) {
                        if (sl.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }

        /// Render GUI views with both visibility and value state overrides.
        ///
        /// Allows full runtime control over element visibility AND values (checkboxes, sliders).
        /// Updates value_state when user interacts with elements.
        pub fn renderSceneGuiWithState(
            self: *Self,
            scene: anytype,
            comptime Views: type,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            if (!self.gui_enabled) return;

            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            self.gui.beginFrame();

            for (view_names) |active_name| {
                self.renderViewByNameWithState(Views, Scripts, active_name, visibility_state, value_state);
            }

            self.gui.endFrame();
        }

        /// Internal: Render view with full state overrides.
        fn renderViewByNameWithState(
            self: *Self,
            comptime Views: type,
            comptime Scripts: type,
            name: []const u8,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElementsWithState(view_def.elements, Scripts, visibility_state, value_state);
                    return;
                }
            }
        }

        /// Internal: Render elements with full state overrides.
        fn renderGuiElementsWithState(
            self: *Self,
            elements: []const gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            for (elements) |element| {
                self.renderGuiElementWithState(element, Scripts, visibility_state, value_state);
            }
        }

        /// Internal: Render single element with full state overrides.
        /// Updates value_state when user interacts with elements.
        fn renderGuiElementWithState(
            self: *Self,
            element: gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            const element_id = element.getId();
            const is_visible = if (element_id.len > 0)
                visibility_state.isVisible(element_id, element.isVisible())
            else
                element.isVisible();

            if (!is_visible) return;

            switch (element) {
                .Label => |lbl| self.gui.label(lbl),
                .Button => |btn| {
                    if (self.gui.button(btn)) {
                        if (btn.on_click) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| self.gui.progressBar(bar),
                .Panel => |panel| {
                    self.gui.beginPanel(panel);
                    self.renderGuiElementsWithState(panel.children, Scripts, visibility_state, value_state);
                    self.gui.endPanel();
                },
                .Image => |img| self.gui.image(img),
                .Checkbox => |cb| {
                    // Apply value state override
                    var modified_cb = cb;
                    if (element_id.len > 0) {
                        modified_cb.checked = value_state.getCheckbox(element_id, cb.checked);
                    }

                    if (self.gui.checkbox(modified_cb)) {
                        // User toggled checkbox - update value state
                        if (element_id.len > 0) {
                            const new_value = !modified_cb.checked;
                            value_state.setCheckbox(element_id, new_value) catch {};
                        }

                        // Invoke callback if defined
                        if (cb.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    // Apply value state override
                    var modified_sl = sl;
                    if (element_id.len > 0) {
                        modified_sl.value = value_state.getSlider(element_id, sl.value);
                    }

                    const new_value = self.gui.slider(modified_sl);
                    if (new_value != modified_sl.value) {
                        // User changed slider - update value state
                        if (element_id.len > 0) {
                            value_state.setSlider(element_id, new_value) catch {};
                        }

                        // Invoke callback if defined
                        if (sl.on_change) |callback_name| {
                            self.invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }

        // ==================== Screenshot ====================

        /// Request a screenshot of the current frame to be saved to a file.
        /// The screenshot is captured at the end of the frame after rendering is complete.
        /// The filename should include the extension (e.g., "screenshot.png").
        pub fn takeScreenshot(self: *Self, filename: [*:0]const u8) void {
            // Free any pending screenshot request
            if (self.pending_screenshot_filename) |old| {
                self.allocator.free(old);
            }
            // Duplicate the filename to store until end of frame
            const slice = std.mem.span(filename);
            self.pending_screenshot_filename = self.allocator.dupeZ(u8, slice) catch {
                std.log.err("Failed to allocate memory for screenshot filename", .{});
                return;
            };
        }

        /// Internal: Process pending screenshot request (called after render)
        fn processPendingScreenshot(self: *Self) void {
            if (self.pending_screenshot_filename) |filename| {
                self.retained_engine.takeScreenshot(filename.ptr);
                self.allocator.free(filename);
                self.pending_screenshot_filename = null;
            }
        }
    };
}

/// Default Game type with hooks disabled for backwards compatibility.
/// Use `GameWith(MyHooks)` to enable lifecycle hooks.
pub const Game = GameWith(void);
