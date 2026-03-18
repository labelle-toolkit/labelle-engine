const std = @import("std");
const core = @import("labelle-core");

const Position = core.Position;
const MockEcsBackend = core.MockEcsBackend;
const HookDispatcher = core.HookDispatcher;
const hooks_types = @import("hooks_types.zig");
const ComponentPayload = hooks_types.ComponentPayload;
const VisualType = core.VisualType;
const ParentComponent = core.ParentComponent;
const ChildrenComponent = core.ChildrenComponent;

const atlas_mod = @import("atlas.zig");
const game_log_mod = @import("game_log.zig");

const hierarchy = @import("game/hierarchy.zig");
const gizmo_draws_mod = @import("game/gizmo_draws.zig");

// Mixin modules — domain-specific method groups
const visuals_mixin = @import("game/visuals.zig");
const input_mixin = @import("game/input_mixin.zig");
const audio_mixin = @import("game/audio_mixin.zig");
const gui_mixin = @import("game/gui_mixin.zig");
const gizmo_mixin = @import("game/gizmo_mixin.zig");
const scene_mixin = @import("game/scene_mixin.zig");

/// Full game configuration — the assembler fills ALL comptime slots.
/// RenderImpl is a renderer plugin (e.g. gfx.GfxRenderer) satisfying RenderInterface.
/// The engine does NOT depend on labelle-gfx — it accesses component types through RenderImpl.
pub fn GameConfig(
    comptime RenderImpl: type,
    comptime EcsImpl: type,
    comptime InputImpl: type,
    comptime AudioImpl: type,
    comptime GuiImpl: type,
    comptime Hooks: type,
    comptime LogSinkImpl: type,
) type {
    // Validate renderer satisfies the contract
    _ = core.RenderInterface(RenderImpl);

    const Entity = EcsImpl.Entity;
    const Sprite = RenderImpl.Sprite;
    const Shape = RenderImpl.Shape;
    const Text = if (@hasDecl(RenderImpl, "Text")) RenderImpl.Text else void;
    const Icon = if (@hasDecl(RenderImpl, "Icon")) RenderImpl.Icon else void;
    const Parent = ParentComponent(Entity);
    const Children = ChildrenComponent(Entity);
    const Payload = hooks_types.HookPayload(Entity);
    const has_hooks = Hooks != void;
    const HooksField = if (has_hooks) ?HookDispatcher(Payload, Hooks, .{}) else void;

    return struct {
        const Self = @This();

        pub const EntityType = Entity;
        pub const EcsBackend = EcsImpl;
        pub const SpriteComp = Sprite;
        pub const ShapeComp = Shape;
        pub const TextComp = Text;
        pub const IconComp = Icon;
        pub const ParentComp = Parent;
        pub const ChildrenComp = Children;
        pub const Input = @import("input.zig").InputInterface(InputImpl);
        pub const Audio = @import("audio.zig").AudioInterface(AudioImpl);
        pub const Gui = @import("gui.zig").GuiInterface(GuiImpl);
        pub const GizmoDraw = gizmo_draws_mod.GizmoDraw;
        pub const Log = game_log_mod.GameLog(LogSinkImpl, core.log.default_min_level);

        // ── Mixin types ──────────────────────────────────────────
        const Visuals = visuals_mixin.Mixin(Self);
        const InputMixin = input_mixin.Mixin(Self);
        const AudioMixin = audio_mixin.Mixin(Self);
        const GuiMixin = gui_mixin.Mixin(Self);
        const GizmoMixin = gizmo_mixin.Mixin(Self);
        const SceneMixin = scene_mixin.Mixin(Self);

        /// Scene lifecycle hooks
        pub const SceneHooks = struct {
            onLoad: ?*const fn (*Self) void = null,
            onUnload: ?*const fn (*Self) void = null,
        };

        pub const SceneEntry = struct {
            loader_fn: *const fn (*Self) anyerror!void,
            hooks: SceneHooks,
        };

        pub const FrameCallback = *const fn (*Self, f32) void;

        allocator: std.mem.Allocator,
        ecs_backend: EcsImpl,
        renderer: RenderImpl,
        atlas_manager: atlas_mod.TextureManager,
        sprite_cache: atlas_mod.SpriteCache,
        hooks: HooksField = if (has_hooks) null else {},

        // Scene management
        scenes: std.StringHashMap(SceneEntry),
        current_scene_name: ?[]const u8 = null,
        pending_scene_change: ?[]const u8 = null,

        // Active scene (type-erased) — managed by sceneLoaderFn / setActiveScene
        active_scene_ptr: ?*anyopaque = null,
        active_scene_update_fn: ?*const fn (*anyopaque, f32) void = null,
        active_scene_deinit_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
        active_scene_get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Entity = null,
        /// Script names listed in the active scene's .scripts field.
        /// null = no filtering (scene without .scripts or no scene), slice = only these run.
        active_scene_script_names: ?[]const []const u8 = null,
        gizmo_reconcile_fn: ?*const fn (*Self) void = null,

        // Arena for heap-allocated slices in nested entity arrays (scene loader).
        // Freed on scene teardown.
        nested_entity_arena: std.heap.ArenaAllocator,

        // Logging
        log: Log = .{},

        // Game state
        running: bool = true,
        frame_number: u64 = 0,

        // Gizmos
        gizmos_enabled: bool = true,
        gizmo_state: gizmo_draws_mod.GizmoState(Entity),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .ecs_backend = EcsImpl.init(allocator),
                .renderer = RenderImpl.init(allocator),
                .atlas_manager = atlas_mod.TextureManager.init(allocator),
                .sprite_cache = atlas_mod.SpriteCache.init(allocator),
                .scenes = std.StringHashMap(SceneEntry).init(allocator),
                .gizmo_state = gizmo_draws_mod.GizmoState(Entity).init(allocator),
                .nested_entity_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.emitHook(.{ .game_deinit = {} });
            self.teardownActiveScene();
            if (self.current_scene_name) |name| {
                self.allocator.free(name);
            }
            if (self.pending_scene_change) |name| {
                self.allocator.free(name);
            }
            self.nested_entity_arena.deinit();
            self.gizmo_state.deinit(self.allocator);
            self.scenes.deinit();
            self.sprite_cache.deinit();
            self.atlas_manager.deinit();
            self.renderer.deinit();
            self.ecs_backend.deinit();
        }

        pub fn setHooks(self: *Self, receiver: Hooks) void {
            if (has_hooks) {
                self.hooks = .{ .receiver = receiver };
                self.emitHook(.{ .game_init = .{ .allocator = self.allocator } });
            }
        }

        pub fn emitHook(self: *Self, payload: Payload) void {
            if (has_hooks) {
                if (self.hooks) |h| {
                    h.emit(payload);
                }
            }
        }

        // ── Entity Management ─────────────────────────────────────

        pub fn createEntity(self: *Self) Entity {
            const entity = self.ecs_backend.createEntity();
            self.emitHook(.{ .entity_created = .{ .entity_id = entity } });
            return entity;
        }

        pub fn destroyEntity(self: *Self, entity: Entity) void {
            if (self.ecs_backend.getComponent(entity, Children)) |children_comp| {
                for (children_comp.getChildren()) |child| {
                    self.destroyEntity(child);
                }
            }
            self.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.ecs_backend.destroyEntity(entity);
            self.emitHook(.{ .entity_destroyed = .{ .entity_id = entity } });
        }

        pub fn destroyEntityOnly(self: *Self, entity: Entity) void {
            self.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.ecs_backend.destroyEntity(entity);
            self.emitHook(.{ .entity_destroyed = .{ .entity_id = entity } });
        }

        // ── Visuals (mixin) ──────────────────────────────────────
        pub const addSprite = Visuals.addSprite;
        pub const addShape = Visuals.addShape;
        pub const addText = Visuals.addText;
        pub const addIcon = Visuals.addIcon;
        pub const addGizmo = Visuals.addGizmo;
        pub const removeSprite = Visuals.removeSprite;
        pub const removeShape = Visuals.removeShape;
        pub const removeText = Visuals.removeText;
        pub const setZIndex = Visuals.setZIndex;

        // ── Position & Hierarchy ──────────────────────────────────

        pub fn setPosition(self: *Self, entity: Entity, pos: Position) void {
            self.ecs_backend.addComponent(entity, pos);
            self.renderer.markPositionDirtyWithChildren(EcsImpl, &self.ecs_backend, entity);
        }

        pub fn getPosition(self: *Self, entity: Entity) Position {
            if (self.ecs_backend.getComponent(entity, Position)) |p| return p.*;
            return Position{};
        }

        pub fn getWorldPosition(self: *Self, entity: Entity) Position {
            return hierarchy.computeWorldPos(EcsImpl, Parent, &self.ecs_backend, entity, 0);
        }

        pub fn setWorldPosition(self: *Self, entity: Entity, world_pos: Position) void {
            if (self.ecs_backend.getComponent(entity, Parent)) |parent_comp| {
                const parent_world = hierarchy.computeWorldPos(EcsImpl, Parent, &self.ecs_backend, parent_comp.entity, 0);
                self.setPosition(entity, .{ .x = world_pos.x - parent_world.x, .y = world_pos.y - parent_world.y });
            } else {
                self.setPosition(entity, world_pos);
            }
        }

        pub fn setParent(self: *Self, child: Entity, parent_entity: Entity, opts: struct {
            inherit_rotation: bool = false,
            inherit_scale: bool = false,
        }) void {
            if (hierarchy.wouldCreateCycle(EcsImpl, Parent, &self.ecs_backend, child, parent_entity)) return;

            if (self.ecs_backend.getComponent(child, Parent)) |old_parent_comp| {
                if (self.ecs_backend.getComponent(old_parent_comp.entity, Children)) |old_children| {
                    old_children.removeChild(child);
                }
            }

            self.ecs_backend.addComponent(child, Parent{
                .entity = parent_entity,
                .inherit_rotation = opts.inherit_rotation,
                .inherit_scale = opts.inherit_scale,
            });

            if (self.ecs_backend.getComponent(parent_entity, Children)) |children_comp| {
                children_comp.addChild(child);
            } else {
                var new_children = Children{};
                new_children.addChild(child);
                self.ecs_backend.addComponent(parent_entity, new_children);
            }

            self.renderer.updateHierarchyFlag(child, true);
            self.renderer.markPositionDirty(child);
        }

        pub fn setParentKeepTransform(self: *Self, child: Entity, parent_entity: Entity, opts: struct {
            inherit_rotation: bool = false,
            inherit_scale: bool = false,
        }) void {
            const world_pos = self.getWorldPosition(child);
            self.setParent(child, parent_entity, opts);
            self.setWorldPosition(child, world_pos);
        }

        pub fn removeParent(self: *Self, child: Entity) void {
            if (self.ecs_backend.getComponent(child, Parent)) |parent_comp| {
                if (self.ecs_backend.getComponent(parent_comp.entity, Children)) |children_comp| {
                    children_comp.removeChild(child);
                }
            }
            self.ecs_backend.removeComponent(child, Parent);
            self.renderer.updateHierarchyFlag(child, false);
            self.renderer.markPositionDirty(child);
        }

        pub fn removeParentKeepTransform(self: *Self, child: Entity) void {
            const world_pos = self.getWorldPosition(child);
            self.removeParent(child);
            self.setPosition(child, world_pos);
        }

        pub fn getParent(self: *Self, entity: Entity) ?Entity {
            if (self.ecs_backend.getComponent(entity, Parent)) |p| return p.entity;
            return null;
        }

        pub fn getChildren(self: *Self, entity: Entity) []const Entity {
            if (self.ecs_backend.getComponent(entity, Children)) |c| return c.getChildren();
            return &.{};
        }

        pub fn hasChildren(self: *Self, entity: Entity) bool {
            if (self.ecs_backend.getComponent(entity, Children)) |c| return c.count() > 0;
            return false;
        }

        pub fn isRoot(self: *Self, entity: Entity) bool {
            return !self.ecs_backend.hasComponent(entity, Parent);
        }

        // ── Generic Component Access ──────────────────────────────

        pub fn addComponent(self: *Self, entity: Entity, component: anytype) void {
            self.ecs_backend.addComponent(entity, component);
            const T = @TypeOf(component);
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onAdd")) {
                T.onAdd(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
        }

        pub fn setComponent(self: *Self, entity: Entity, component: anytype) void {
            const T = @TypeOf(component);
            const is_update = self.ecs_backend.hasComponent(entity, T);
            self.ecs_backend.addComponent(entity, component);
            if (@typeInfo(T) == .@"struct") {
                if (is_update and @hasDecl(T, "onSet")) {
                    T.onSet(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
                } else if (!is_update and @hasDecl(T, "onAdd")) {
                    T.onAdd(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
                }
            }
        }

        pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
            return self.ecs_backend.getComponent(entity, T);
        }

        pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
            return self.ecs_backend.hasComponent(entity, T);
        }

        pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onRemove")) {
                T.onRemove(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
            self.ecs_backend.removeComponent(entity, T);
        }

        /// Fire onReady for a component type on a given entity.
        /// Called by the scene loader after ALL components have been added,
        /// so onReady callbacks can safely access sibling components.
        pub fn fireOnReady(self: *Self, entity: Entity, comptime T: type) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onReady")) {
                T.onReady(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
        }

        // ── Input (mixin) ────────────────────────────────────────
        pub const isKeyDown = InputMixin.isKeyDown;
        pub const isKeyPressed = InputMixin.isKeyPressed;
        pub const getMouseX = InputMixin.getMouseX;
        pub const getMouseY = InputMixin.getMouseY;
        pub const getMouse = InputMixin.getMouse;

        // ── Audio (mixin) ────────────────────────────────────────
        pub const playSound = AudioMixin.playSound;
        pub const stopSound = AudioMixin.stopSound;
        pub const setVolume = AudioMixin.setVolume;

        // ── GUI (mixin) ──────────────────────────────────────────
        pub const guiBegin = GuiMixin.guiBegin;
        pub const guiEnd = GuiMixin.guiEnd;
        pub const guiWantsMouse = GuiMixin.guiWantsMouse;
        pub const guiWantsKeyboard = GuiMixin.guiWantsKeyboard;
        pub const renderAllViews = GuiMixin.renderAllViews;
        pub const renderView = GuiMixin.renderView;

        // ── Gizmos (mixin) ───────────────────────────────────────
        pub const setGizmosEnabled = GizmoMixin.setGizmosEnabled;
        pub const isGizmosEnabled = GizmoMixin.isGizmosEnabled;
        pub const drawGizmoLine = GizmoMixin.drawGizmoLine;
        pub const drawGizmoRect = GizmoMixin.drawGizmoRect;
        pub const drawGizmoCircle = GizmoMixin.drawGizmoCircle;
        pub const drawGizmoArrow = GizmoMixin.drawGizmoArrow;
        pub const drawGizmoLineScreen = GizmoMixin.drawGizmoLineScreen;
        pub const drawGizmoRectScreen = GizmoMixin.drawGizmoRectScreen;
        pub const drawGizmoCircleScreen = GizmoMixin.drawGizmoCircleScreen;
        pub const drawGizmoArrowScreen = GizmoMixin.drawGizmoArrowScreen;
        pub const clearGizmos = GizmoMixin.clearGizmos;
        pub const clearGizmoGroup = GizmoMixin.clearGizmoGroup;
        pub const getGizmoDraws = GizmoMixin.getGizmoDraws;
        pub const selectEntity = GizmoMixin.selectEntity;
        pub const deselectEntity = GizmoMixin.deselectEntity;
        pub const isEntitySelected = GizmoMixin.isEntitySelected;
        pub const clearSelection = GizmoMixin.clearSelection;
        pub const renderGizmos = GizmoMixin.renderGizmos;

        // ── Scene Management (mixin) ─────────────────────────────
        pub const registerScene = SceneMixin.registerScene;
        pub const registerSceneSimple = SceneMixin.registerSceneSimple;
        pub const setScene = SceneMixin.setScene;
        pub const queueSceneChange = SceneMixin.queueSceneChange;
        pub const getCurrentSceneName = SceneMixin.getCurrentSceneName;
        pub fn unloadCurrentScene(self: *Self) void {
            if (self.current_scene_name) |name| {
                self.emitHook(.{ .scene_unload = .{ .name = name } });
                if (self.scenes.get(name)) |entry| {
                    if (entry.hooks.onUnload) |onUnload| {
                        onUnload(self);
                    }
                }
            }
            // Scene deinit destroys non-persistent entities (which untracks them
            // from the renderer). Persistent entities remain in ECS + renderer.
            self.teardownActiveScene();
        }

        /// Store a type-erased active scene. Called by sceneLoaderFn to hand
        /// the heap-allocated Scene to the engine for lifecycle management.
        pub fn setActiveScene(
            self: *Self,
            ptr: *anyopaque,
            update_fn: *const fn (*anyopaque, f32) void,
            deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
            get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Entity,
            script_names: ?[]const []const u8,
        ) void {
            self.teardownActiveScene();
            self.active_scene_ptr = ptr;
            self.active_scene_update_fn = update_fn;
            self.active_scene_deinit_fn = deinit_fn;
            self.active_scene_get_entity_fn = get_entity_fn;
            self.active_scene_script_names = script_names;
        }

        /// Returns the active scene's script name list for ScriptRunner filtering.
        /// null = no filtering (tick all), slice = only tick listed scripts.
        pub fn getActiveScriptNames(self: *const Self) ?[]const []const u8 {
            return self.active_scene_script_names;
        }

        /// Look up a named entity from the active scene.
        pub fn getEntityByName(self: *const Self, name: []const u8) ?Entity {
            if (self.active_scene_ptr) |ptr| {
                if (self.active_scene_get_entity_fn) |get_fn| {
                    return get_fn(ptr, name);
                }
            }
            return null;
        }

        pub fn teardownActiveScene(self: *Self) void {
            if (self.active_scene_ptr) |ptr| {
                if (self.active_scene_deinit_fn) |deinit_fn| {
                    deinit_fn(ptr, self.allocator);
                }
                self.active_scene_ptr = null;
                self.active_scene_update_fn = null;
                self.active_scene_deinit_fn = null;
                self.active_scene_get_entity_fn = null;
                self.active_scene_script_names = null;
                self.sprite_cache.clear();
                // Free nested entity array allocations from the outgoing scene
                _ = self.nested_entity_arena.reset(.retain_capacity);
            }
        }

        // ── Game Loop ─────────────────────────────────────────────

        pub fn quit(self: *Self) void {
            self.running = false;
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        pub fn tick(self: *Self, dt: f32) void {
            self.log.update(dt);
            self.emitHook(.{ .frame_start = .{ .frame_number = self.frame_number, .dt = dt } });
            Audio.update();
            Input.updateGestures(dt); // Poll gesture recognition (no-op if backend lacks touch support)
            self.resolveAtlasSprites();
            self.renderer.sync(EcsImpl, &self.ecs_backend);

            if (self.pending_scene_change) |next_scene| {
                defer {
                    self.allocator.free(next_scene);
                    self.pending_scene_change = null;
                }
                self.setScene(next_scene) catch {};
            }

            if (self.active_scene_ptr) |scene_ptr| {
                if (self.active_scene_update_fn) |update_fn| {
                    update_fn(scene_ptr, dt);
                }
            }

            // Reconcile gizmos for runtime-created entities
            if (self.gizmo_reconcile_fn) |reconcile_fn| {
                reconcile_fn(self);
            }

            self.emitHook(.{ .frame_end = .{ .frame_number = self.frame_number, .dt = dt } });
            self.frame_number += 1;
        }

        pub fn render(self: *Self) void {
            self.renderer.render();
            self.renderGizmos();
            self.clearGizmos();
        }

        // ── Camera ────────────────────────────────────────────────

        const has_camera = @hasDecl(RenderImpl, "CameraType");
        pub const CameraType = if (has_camera) RenderImpl.CameraType else void;
        pub const CameraManagerType = if (has_camera) RenderImpl.CameraManagerType else void;

        /// Get the primary camera (for renderers that support cameras).
        pub const getCamera = if (has_camera) getCameraImpl else void;
        fn getCameraImpl(self: *Self) *CameraType {
            return self.renderer.getCamera();
        }

        /// Get the camera manager (for multi-camera / split-screen).
        pub const getCameraManager = if (has_camera) getCameraManagerImpl else void;
        fn getCameraManagerImpl(self: *Self) *CameraManagerType {
            return self.renderer.getCameraManager();
        }

        // ── Atlas ─────────────────────────────────────────────────

        const has_load_texture = @hasDecl(RenderImpl, "loadTexture");

        /// Load a TexturePacker JSON atlas. Parses the JSON into the engine's
        /// TextureManager and loads the texture via the renderer.
        /// Only available when the renderer supports loadTexture.
        pub const loadAtlas = if (has_load_texture) loadAtlasImpl else @compileError("Renderer does not support loadTexture");

        fn loadAtlasImpl(self: *Self, name: []const u8, json_path: [:0]const u8, texture_path: [:0]const u8) !void {
            const tex_id = try self.renderer.loadTexture(texture_path);
            // Convert renderer's TextureId (enum/opaque) to u32 for engine storage
            const id: u32 = if (@typeInfo(@TypeOf(tex_id)) == .@"enum")
                @intFromEnum(tex_id)
            else
                tex_id;
            try self.atlas_manager.loadAtlasFromJson(name, json_path, id);
        }

        /// Load an atlas from comptime sprite data (zero runtime parsing).
        /// Usage: game.loadAtlasComptime("chars", &MyAtlas.sprites, "chars.png");
        /// Only available when the renderer supports loadTexture.
        pub const loadAtlasComptime = if (has_load_texture) loadAtlasComptimeImpl else @compileError("Renderer does not support loadTexture");

        fn loadAtlasComptimeImpl(self: *Self, name: []const u8, comptime sprites: []const atlas_mod.SpriteData, texture_path: [:0]const u8) !void {
            const tex_id = try self.renderer.loadTexture(texture_path);
            const id: u32 = if (@typeInfo(@TypeOf(tex_id)) == .@"enum")
                @intFromEnum(tex_id)
            else
                tex_id;
            try self.atlas_manager.loadAtlasComptime(name, sprites, id);
        }

        pub fn getTextureManager(self: *Self) *atlas_mod.TextureManager {
            return &self.atlas_manager;
        }

        /// Look up a sprite by name across all loaded atlases (uncached).
        pub fn findSprite(self: *const Self, sprite_name: []const u8) ?atlas_mod.FindSpriteResult {
            return self.atlas_manager.findSprite(sprite_name);
        }

        /// Look up a sprite for an entity using the per-entity cache.
        /// Returns cached result when atlas version and sprite name haven't changed.
        pub fn findSpriteCached(self: *Self, entity_id: u32, sprite_name: []const u8) ?atlas_mod.FindSpriteResult {
            return self.sprite_cache.lookup(entity_id, sprite_name, &self.atlas_manager);
        }

        /// Unload an atlas by name, freeing sprite data.
        pub fn unloadAtlas(self: *Self, name: []const u8) void {
            self.atlas_manager.unloadAtlas(name);
        }

        // ── Atlas Resolution ──────────────────────────────────────

        const has_atlas_sprite_fields = @hasField(Sprite, "source_rect") and @hasField(Sprite, "texture") and @hasField(Sprite, "sprite_name");

        /// Resolve sprite_name → source_rect + texture for all atlas sprites.
        /// Called automatically before renderer sync each frame.
        /// Only marks entities dirty on cache misses (sprite name or atlas version changed).
        fn resolveAtlasSprites(self: *Self) void {
            if (!has_atlas_sprite_fields) return;
            if (self.atlas_manager.atlasCount() == 0) return;

            var v = self.ecs_backend.view(.{Sprite}, .{});
            defer v.deinit();
            while (v.next()) |entity| {
                const sprite = self.ecs_backend.getComponent(entity, Sprite).?;
                if (sprite.sprite_name.len == 0) continue;

                const misses_before = self.sprite_cache.misses;
                if (self.sprite_cache.lookup(@intCast(entity), sprite.sprite_name, &self.atlas_manager)) |result| {
                    // Only update and mark dirty on cache miss (new sprite or atlas changed)
                    if (self.sprite_cache.misses != misses_before) {
                        sprite.texture = @enumFromInt(result.texture_id);
                        sprite.source_rect = .{
                            .x = @floatFromInt(result.sprite.x),
                            .y = @floatFromInt(result.sprite.y),
                            .width = @floatFromInt(result.sprite.getWidth()),
                            .height = @floatFromInt(result.sprite.getHeight()),
                        };
                        self.renderer.markVisualDirty(entity);
                    }
                }
            }
        }

        // ── Accessors ─────────────────────────────────────────────

        pub fn getRenderer(self: *Self) *RenderImpl {
            return &self.renderer;
        }

        pub fn getEcsBackend(self: *Self) *EcsImpl {
            return &self.ecs_backend;
        }

        pub fn entityCount(self: *Self) usize {
            return @intCast(self.ecs_backend.entityCount());
        }
    };
}

/// Convenience: Game with custom hooks, StubRender + mock ECS
pub fn GameWith(comptime Hooks: type) type {
    return GameConfig(
        core.StubRender(MockEcsBackend(u32).Entity),
        MockEcsBackend(u32),
        @import("input.zig").StubInput,
        @import("audio.zig").StubAudio,
        @import("gui.zig").StubGui,
        Hooks,
        core.StubLogSink,
    );
}

/// Convenience: full mock game for testing
pub const Game = GameWith(void);
