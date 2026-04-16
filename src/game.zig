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
const assets_mod = @import("assets/mod.zig");
const game_log_mod = @import("game_log.zig");

const hierarchy = @import("game/hierarchy.zig");
const gizmo_draws_mod = @import("game/gizmo_draws.zig");
const builtin = @import("builtin");

// Mixin modules — domain-specific method groups
const visuals_mixin = @import("game/visuals.zig");
const input_mixin = @import("game/input_mixin.zig");
const audio_mixin = @import("game/audio_mixin.zig");
const gui_mixin = @import("game/gui_mixin.zig");
const gizmo_mixin = @import("game/gizmo_mixin.zig");
const scene_mixin = @import("game/scene_mixin.zig");
const save_load_mixin = @import("game/save_load_mixin.zig");
const state_mixin = @import("game/state_mixin.zig");

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
    comptime ComponentsType: type,
    comptime GizmoCategoriesSlice: anytype,
    comptime GameEvents: type,
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
    const EnginePayload = hooks_types.HookPayload(Entity);
    const has_events = GameEvents != void;
    const Payload = if (has_events) core.MergeHookPayloads(.{ EnginePayload, GameEvents }) else EnginePayload;
    const has_hooks = Hooks != void;
    const HooksIsMerged = has_hooks and @typeInfo(Hooks) == .pointer and @hasDecl(@typeInfo(Hooks).pointer.child, "emit");
    const HooksField = if (!has_hooks)
        void
    else if (HooksIsMerged)
        ?Hooks
    else
        ?HookDispatcher(Payload, Hooks, .{});
    const EventBuffer = if (has_events) std.ArrayList(GameEvents) else void;

    return struct {
        const Self = @This();
        const is_debug = builtin.mode == .Debug;

        // Debug-only: entity tombstone tracking (#419, #420)
        pub const tombstone_size = 64;
        pub const TombstoneEntry = struct { entity: Entity, frame: u64 };

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
        /// Component registry — for debug introspection by plugins.
        pub const ComponentRegistry = ComponentsType;
        /// Gizmo categories discovered from plugins at comptime.
        pub const gizmo_categories = GizmoCategoriesSlice;

        // ── Mixin types ──────────────────────────────────────────
        const Visuals = visuals_mixin.Mixin(Self);
        const InputMixin = input_mixin.Mixin(Self);
        const AudioMixin = audio_mixin.Mixin(Self);
        const GuiMixin = gui_mixin.Mixin(Self);
        const GizmoMixin = gizmo_mixin.Mixin(Self);
        const SceneMixin = scene_mixin.Mixin(Self);
        const SaveLoadMixin = save_load_mixin.Mixin(Self);
        const StateMixin = state_mixin.Mixin(Self);

        /// Scene lifecycle hooks
        pub const SceneHooks = struct {
            onLoad: ?*const fn (*Self) void = null,
            onUnload: ?*const fn (*Self) void = null,
        };

        pub const SceneEntry = struct {
            loader_fn: *const fn (*Self) anyerror!void,
            hooks: SceneHooks,
            /// Declared asset manifest for this scene — the slice of asset names
            /// the scene needs loaded before it runs. Populated by the assembler
            /// from each scene's `"assets": [...]` block (see Asset Streaming
            /// RFC #437 / issue #445). Defaults to an empty slice for scenes
            /// registered via the legacy (non-manifest) path; scripts can then
            /// do `game.scenes.get("main").?.assets` without a null check.
            assets: []const []const u8 = &.{},
        };

        /// Runtime JSONC scene path info.
        pub const JsoncSceneInfo = struct {
            scene_path: []const u8,
            prefab_dir: []const u8,
        };

        pub const FrameCallback = *const fn (*Self, f32) void;

        /// A world bundles ECS, renderer, sprite cache, and arena.
        /// The active world is a heap-allocated pointer for stable references.
        /// Inactive worlds live in the `worlds` map as heap pointers.
        pub const World = struct {
            ecs_backend: EcsImpl,
            renderer: RenderImpl,
            sprite_cache: atlas_mod.SpriteCache,
            nested_entity_arena: std.heap.ArenaAllocator,

            pub fn init(allocator: std.mem.Allocator) World {
                return .{
                    .ecs_backend = EcsImpl.init(allocator),
                    .renderer = RenderImpl.init(allocator),
                    .sprite_cache = atlas_mod.SpriteCache.init(allocator),
                    .nested_entity_arena = std.heap.ArenaAllocator.init(allocator),
                };
            }

            pub fn deinit(self: *World) void {
                self.nested_entity_arena.deinit();
                self.sprite_cache.deinit();
                self.renderer.deinit();
                self.ecs_backend.deinit();
            }
        };

        allocator: std.mem.Allocator,
        active_world: *World,
        /// Backward-compatible ECS access — always points to active world's ECS.
        ecs_backend: *EcsImpl = undefined,
        /// Backward-compatible renderer access — always points to active world's renderer.
        renderer: *RenderImpl = undefined,
        worlds: std.StringHashMap(*World),
        active_world_name: ?[]const u8 = null,
        atlas_manager: atlas_mod.TextureManager,
        /// Streaming asset catalog — register + refcounted acquire/release
        /// for atlases, audio, fonts, etc. Worker thread is spawned lazily
        /// on the first `acquire` (see `assets/catalog.zig`), so wiring
        /// this eagerly in `Game.init` is near-free for games that never
        /// stream anything. Scripts call `game.assets.acquire(...)`,
        /// `game.assets.progress(...)`, etc. directly.
        ///
        /// The `loadAtlas*` family in this file pumps image decodes
        /// through this catalog instead of calling
        /// `renderer.loadTextureFromMemory` on the main thread — see
        /// `loadAtlasIfNeededImpl` below. Every asset registered through
        /// `registerAtlasFromMemory` / `loadAtlasFromMemory` gets a
        /// parallel entry here keyed by the same name so the PNG decode
        /// runs off-thread even for the legacy eager path.
        ///
        /// `pump()` is the caller's responsibility for now: the engine
        /// tick does NOT call it automatically. Automatic per-frame
        /// pumping is deferred to the scene-hooks ticket (#444) so the
        /// design can be settled alongside scene-manifest auto-acquire.
        assets: assets_mod.AssetCatalog,
        hooks: HooksField = if (has_hooks) null else {},
        event_buffer: EventBuffer = if (has_events) .{} else {},

        // Scene management
        scenes: std.StringHashMap(SceneEntry),
        jsonc_scenes: std.StringHashMap(JsoncSceneInfo),
        /// Entities created by the active scene's loader (e.g. the JSONC
        /// bridge). `unloadCurrentScene` destroys everything in this list
        /// on scene swap so entities from the outgoing scene don't leak
        /// into the incoming one. Loaders MUST call `trackSceneEntity`
        /// for every entity they create.
        scene_entities: std.ArrayList(Entity) = .{},
        current_scene_name: ?[]const u8 = null,
        pending_scene_change: ?[]const u8 = null,
        pending_scene_atomic: bool = false,

        /// Phase 2 of the Asset Streaming RFC (#437). Tracks the
        /// scene name we have already called `assets.acquire()` for
        /// from inside `setScene` / `setSceneAtomic`. The transition
        /// is poll-driven: if the manifest is not yet `allReady`,
        /// `setScene` returns early and the script keeps calling it
        /// every frame. `pending_scene_assets` is the idempotency
        /// guard — without it we would re-acquire on every frame
        /// and the refcount would never come back to zero.
        ///
        /// Cleared after the swap completes (success path) or after
        /// an explicit abort (`scene_assets_release_pending`).
        pending_scene_assets: ?[]const u8 = null,

        // Active scene (type-erased) — managed by sceneLoaderFn / setActiveScene
        active_scene_ptr: ?*anyopaque = null,
        active_scene_update_fn: ?*const fn (*anyopaque, f32) void = null,
        active_scene_deinit_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
        active_scene_get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Entity = null,
        active_scene_add_entity_fn: ?*const fn (*anyopaque, Entity) void = null,
        active_scene_clear_entities_fn: ?*const fn (*anyopaque) void = null,


        gizmo_reconcile_fn: ?*const fn (*Self) void = null,

        // Prefab spawning — set by JSONC scene bridge during loadScene.
        prefab_dir: ?[]const u8 = null,
        spawn_prefab_fn: ?*const fn (*Self, []const u8, Position) ?Entity = null,
        prefab_cache_ptr: ?*anyopaque = null,

        // Logging
        log: Log = .{},

        // Game state
        running: bool = true,
        frame_number: u64 = 0,
        /// Current game state (e.g. "menu", "playing", "paused").
        /// Set via setState() or queueStateChange(). Default is "running".
        game_state: []const u8 = "running",
        pending_state_change: ?[]const u8 = null,
        state_change_count: usize = 0,
        /// Time scale factor: 0 = paused, 0.5 = slow-mo, 1.0 = normal, 2.0 = fast.
        /// When paused (0), rendering and GUI continue but tick logic stops.
        time_scale: f32 = 1.0,

        // Profiling (debug builds only)
        /// Opaque pointer to ScriptRunner's profile array. Set by generated code.
        script_profile_ptr: ?*const anyopaque = null,
        script_profile_count: usize = 0,
        /// Opaque pointer to SystemRegistry's plugin_profile array. Set by generated code.
        plugin_profile_ptr: ?*const anyopaque = null,
        plugin_profile_count: usize = 0,

        // Hot reload
        hot_reload_dirty: bool = false,

        // Gizmos
        gizmos_enabled: bool = true,
        gizmo_state: gizmo_draws_mod.GizmoState(Entity),

        // Debug-only: tombstone ring buffer (#420)
        tombstones: if (is_debug) [tombstone_size]?TombstoneEntry else void =
            if (is_debug) [_]?TombstoneEntry{null} ** tombstone_size else {},
        tombstone_cursor: if (is_debug) usize else void =
            if (is_debug) 0 else {},

        pub fn init(allocator: std.mem.Allocator) Self {
            const world = allocator.create(World) catch @panic("failed to allocate default world");
            world.* = World.init(allocator);
            return .{
                .allocator = allocator,
                .active_world = world,
                .ecs_backend = &world.ecs_backend,
                .renderer = &world.renderer,
                .worlds = std.StringHashMap(*World).init(allocator),
                .atlas_manager = atlas_mod.TextureManager.init(allocator),
                .assets = assets_mod.AssetCatalog.init(allocator),
                .scenes = std.StringHashMap(SceneEntry).init(allocator),
                .jsonc_scenes = std.StringHashMap(JsoncSceneInfo).init(allocator),
                .gizmo_state = gizmo_draws_mod.GizmoState(Entity).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.emitHook(.{ .game_deinit = {} });
            // Tear down the active scene FIRST. Scene teardown runs
            // user-provided `deinit_fn`s that may call `game.assets.*`
            // (release on unload is the natural pattern for the very
            // API this PR is exposing), so the catalog MUST still be
            // alive through it. Worker-thread safety is handled inside
            // `AssetCatalog.deinit` — it stops the worker and drains
            // the result ring before touching the hashmap, and its
            // allocator is the Game's allocator which stays live
            // through this whole call.
            if (has_events) self.event_buffer.deinit(self.allocator);
            self.teardownActiveScene();
            self.scene_entities.deinit(self.allocator);
            self.assets.deinit();
            if (self.current_scene_name) |name| {
                self.allocator.free(name);
            }
            if (self.pending_scene_change) |name| {
                self.allocator.free(name);
            }
            if (self.pending_scene_assets) |name| {
                self.allocator.free(name);
            }
            // Clean up inactive worlds
            var world_iter = self.worlds.iterator();
            while (world_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.worlds.deinit();
            if (self.active_world_name) |name| {
                self.allocator.free(name);
            }
            // Clean up active world
            self.active_world.deinit();
            self.allocator.destroy(self.active_world);
            self.gizmo_state.deinit(self.allocator);
            self.scenes.deinit();
            self.jsonc_scenes.deinit();
            self.atlas_manager.deinit();
        }

        pub fn setHooks(self: *Self, receiver: Hooks) void {
            if (has_hooks) {
                if (HooksIsMerged) {
                    self.hooks = receiver;
                    // Inject game pointer into hook structs that declare game_ptr
                    const merged = receiver.*;
                    inline for (std.meta.fields(@TypeOf(merged.receivers))) |field| {
                        const hook_ptr = @field(merged.receivers, field.name);
                        const HookType = @typeInfo(@TypeOf(hook_ptr)).pointer.child;
                        if (@hasField(HookType, "game_ptr")) {
                            hook_ptr.game_ptr = @ptrCast(self);
                        }
                    }
                } else {
                    self.hooks = .{ .receiver = receiver };
                    // Inject game pointer for single hook
                    const HookType = @typeInfo(Hooks).pointer.child;
                    if (@hasField(HookType, "game_ptr")) {
                        receiver.game_ptr = @ptrCast(self);
                    }
                }
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

        /// Emit a game event. Buffered and delivered to scripts at end of frame.
        pub fn emit(self: *Self, event: GameEvents) void {
            if (has_events) {
                self.event_buffer.append(self.allocator, event) catch |err| {
                    self.log.err("Failed to emit game event: {s}", .{@errorName(err)});
                };
            }
        }

        /// Deliver buffered game events to hooks. Called at end of frame.
        pub fn dispatchEvents(self: *Self) void {
            if (!has_events) return;
            var dispatch_buf: EventBuffer = .{};
            std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);

            for (dispatch_buf.items) |event| {
                switch (event) {
                    inline else => |data, tag| {
                        self.emitHook(@unionInit(Payload, @tagName(tag), data));
                    },
                }
            }
            dispatch_buf.clearRetainingCapacity();

            if (self.event_buffer.items.len == 0) {
                std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);
            }
            dispatch_buf.deinit(self.allocator);
        }

        // ── Debug entity guards (#419, #420) ─────────────────────

        fn recordTombstone(self: *Self, entity: Entity) void {
            if (comptime is_debug) {
                self.tombstones[self.tombstone_cursor] = TombstoneEntry{ .entity = entity, .frame = self.frame_number };
                self.tombstone_cursor = (self.tombstone_cursor + 1) % tombstone_size;
            }
        }

        pub fn findTombstone(self: *const Self, entity: Entity) ?TombstoneEntry {
            if (comptime !is_debug) return null;
            // Iterate backwards from cursor to return the most recent match
            // (entity IDs can be reused after resetEcsBackend or ECS recycling)
            var j: usize = 0;
            while (j < tombstone_size) : (j += 1) {
                const i = (self.tombstone_cursor + tombstone_size - 1 - j) % tombstone_size;
                if (self.tombstones[i]) |entry| {
                    if (entry.entity == entity) return entry;
                }
            }
            return null;
        }

        pub fn assertEntityAlive(self: *const Self, entity: Entity, comptime operation: []const u8) void {
            if (comptime is_debug) {
                if (!self.ecs_backend.entityExists(entity)) {
                    if (self.findTombstone(entity)) |tomb| {
                        std.debug.print("{s} on destroyed entity {d} (destroyed in frame {d}, current frame {d})\n", .{
                            operation, entity, tomb.frame, self.frame_number,
                        });
                        @panic(operation ++ " on destroyed entity");
                    } else {
                        std.debug.print("{s} on invalid entity {d} (not in tombstone ring — destroyed long ago or never existed)\n", .{
                            operation, entity,
                        });
                        @panic(operation ++ " on invalid entity");
                    }
                }
            }
        }

        // ── Entity Management ─────────────────────────────────────

        pub fn createEntity(self: *Self) Entity {
            const entity = self.ecs_backend.createEntity();
            self.emitHook(.{ .entity_created = .{ .entity_id = entity } });
            return entity;
        }

        /// Spawn an entity from a named prefab at the given position.
        /// Returns the entity, or null if the prefab was not found.
        /// Requires a JSONC scene to have been loaded (which sets up the prefab directory).
        pub fn spawnPrefab(self: *Self, name: []const u8, pos: Position) ?Entity {
            if (self.spawn_prefab_fn) |func| {
                return func(self, name, pos);
            }
            self.log.err("[Game] spawnPrefab: no prefab loader configured (load a JSONC scene first)", .{});
            return null;
        }

        pub fn destroyEntity(self: *Self, entity: Entity) void {
            if (self.ecs_backend.getComponent(entity, Children)) |children_comp| {
                for (children_comp.getChildren()) |child| {
                    self.destroyEntity(child);
                }
            }
            self.untrackSceneEntity(entity);
            self.active_world.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.ecs_backend.destroyEntity(entity);
            self.recordTombstone(entity);
            self.emitHook(.{ .entity_destroyed = .{ .entity_id = entity } });
        }

        pub fn destroyEntityOnly(self: *Self, entity: Entity) void {
            self.untrackSceneEntity(entity);
            self.active_world.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.ecs_backend.destroyEntity(entity);
            self.recordTombstone(entity);
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
            self.renderer.markPositionDirtyWithChildren(EcsImpl, self.ecs_backend, entity);
        }

        pub fn getPosition(self: *Self, entity: Entity) Position {
            if (self.ecs_backend.getComponent(entity, Position)) |p| return p.*;
            return Position{};
        }

        pub fn getWorldPosition(self: *Self, entity: Entity) Position {
            return hierarchy.computeWorldPos(EcsImpl, Parent, self.ecs_backend, entity, 0);
        }

        pub fn setWorldPosition(self: *Self, entity: Entity, world_pos: Position) void {
            if (self.ecs_backend.getComponent(entity, Parent)) |parent_comp| {
                const parent_world = hierarchy.computeWorldPos(EcsImpl, Parent, self.ecs_backend, parent_comp.entity, 0);
                self.setPosition(entity, .{ .x = world_pos.x - parent_world.x, .y = world_pos.y - parent_world.y });
            } else {
                self.setPosition(entity, world_pos);
            }
        }

        pub fn setParent(self: *Self, child: Entity, parent_entity: Entity, opts: struct {
            inherit_rotation: bool = false,
            inherit_scale: bool = false,
        }) void {
            self.assertEntityAlive(child, "setParent (child)");
            self.assertEntityAlive(parent_entity, "setParent (parent)");
            if (hierarchy.wouldCreateCycle(EcsImpl, Parent, self.ecs_backend, child, parent_entity)) return;

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
            self.assertEntityAlive(child, "removeParent");
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
        pub const getMouseWheelMove = InputMixin.getMouseWheelMove;
        pub const getTouchCount = InputMixin.getTouchCount;
        pub const getTouchX = InputMixin.getTouchX;
        pub const getTouchY = InputMixin.getTouchY;
        pub const getTouchId = InputMixin.getTouchId;

        /// Convert a physical-pixel screen coordinate (raw touch / mouse
        /// event coords from the backend) to a design-pixel coordinate
        /// inside the pillarboxed/letterboxed canvas. Use this before
        /// feeding touch / mouse coords to `cam.screenToWorld` so the
        /// math lines up with the game's design coordinate system.
        ///
        /// Backends without a design/physical distinction (raylib) get
        /// a passthrough — the input is returned unchanged.
        pub fn screenToDesign(self: *Self, px: f32, py: f32) RenderImpl.ScreenPoint {
            return self.renderer.screenToDesign(px, py);
        }

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
        pub const drawGizmoLineCategory = GizmoMixin.drawGizmoLineCategory;
        pub const drawGizmoRectCategory = GizmoMixin.drawGizmoRectCategory;
        pub const drawGizmoCircleCategory = GizmoMixin.drawGizmoCircleCategory;
        pub const drawGizmoArrowCategory = GizmoMixin.drawGizmoArrowCategory;
        pub const setGizmoCategory = GizmoMixin.setGizmoCategory;
        pub const isGizmoCategoryEnabled = GizmoMixin.isGizmoCategoryEnabled;
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
        pub const registerSceneWithAssets = SceneMixin.registerSceneWithAssets;
        pub const setSceneAssets = SceneMixin.setSceneAssets;
        pub const setScene = SceneMixin.setScene;
        pub const setSceneAtomic = SceneMixin.setSceneAtomic;
        pub const queueSceneChange = SceneMixin.queueSceneChange;
        pub const queueSceneChangeAtomic = SceneMixin.queueSceneChangeAtomic;
        pub const getCurrentSceneName = SceneMixin.getCurrentSceneName;

        /// Register a runtime JSONC scene by name.
        /// The scene file is loaded from disk when setScene() is called.
        pub fn registerJsoncScene(self: *Self, name: []const u8, scene_path: []const u8, prefab_dir: []const u8) void {
            self.jsonc_scenes.put(name, .{
                .scene_path = scene_path,
                .prefab_dir = prefab_dir,
            }) catch {};
        }

        // ── Hot Reload ──────────────────────────────────────────────

        /// Signal that the current scene should be reloaded on the next tick.
        pub fn requestReload(self: *Self) void {
            self.hot_reload_dirty = true;
        }

        // ── Save/Load (mixin) ───────────────────────────────────────
        pub const saveGameState = SaveLoadMixin.saveGameState;
        pub const loadGameState = SaveLoadMixin.loadGameState;

        // ── Game State Machine (mixin) ──────────────────────────────
        pub const setState = StateMixin.setState;
        pub const queueStateChange = StateMixin.queueStateChange;
        pub const getState = StateMixin.getState;

        pub fn unloadCurrentScene(self: *Self) void {
            if (has_events) self.event_buffer.clearRetainingCapacity();
            if (self.current_scene_name) |name| {
                self.emitHook(.{ .scene_unload = .{ .name = name } });
                if (self.scenes.get(name)) |entry| {
                    if (entry.hooks.onUnload) |onUnload| {
                        onUnload(self);
                    }
                }
            }
            // Destroy every entity the outgoing scene's loader created.
            // `destroyEntityOnly` skips the children-recursion so a parent
            // destroy doesn't double-free an already-listed child, and it
            // calls `untrackSceneEntity` which swap-removes from this same
            // list — so we pop from the end instead of iterating by index
            // (which would skip entries).
            while (self.scene_entities.pop()) |entity| {
                self.destroyEntityOnly(entity);
            }

            // Scene deinit destroys non-persistent entities (which untracks them
            // from the renderer). Persistent entities remain in ECS + renderer.
            self.teardownActiveScene();
        }

        /// Register an entity as owned by the current scene. Called by
        /// scene loaders (JSONC bridge, comptime registerScene callbacks)
        /// so `unloadCurrentScene` can destroy the entity when the scene
        /// swaps out. Silently no-ops on OOM — the scene still works, we
        /// just lose the auto-cleanup for the un-tracked entity.
        pub fn trackSceneEntity(self: *Self, entity: Entity) void {
            self.scene_entities.append(self.allocator, entity) catch {};
        }

        /// Remove an entity from the scene-tracking list. Called by
        /// `destroyEntity`/`destroyEntityOnly` so (1) a scene's cleanup
        /// loop never double-destroys a tracked-then-manually-destroyed
        /// entity and (2) the list doesn't grow unboundedly across a
        /// scene that churns through short-lived entities. O(N) scan +
        /// swap-remove — fine for scenes with hundreds of entities;
        /// revisit if a project pushes tens of thousands.
        fn untrackSceneEntity(self: *Self, entity: Entity) void {
            var i: usize = 0;
            while (i < self.scene_entities.items.len) : (i += 1) {
                if (self.scene_entities.items[i] == entity) {
                    _ = self.scene_entities.swapRemove(i);
                    return;
                }
            }
        }

        /// Store a type-erased active scene. Called by sceneLoaderFn to hand
        /// the heap-allocated Scene to the engine for lifecycle management.
        pub fn setActiveScene(
            self: *Self,
            ptr: *anyopaque,
            update_fn: *const fn (*anyopaque, f32) void,
            deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
            get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Entity,
            add_entity_fn: ?*const fn (*anyopaque, Entity) void,
            clear_entities_fn: ?*const fn (*anyopaque) void,
        ) void {
            self.teardownActiveScene();
            self.active_scene_ptr = ptr;
            self.active_scene_update_fn = update_fn;
            self.active_scene_deinit_fn = deinit_fn;
            self.active_scene_get_entity_fn = get_entity_fn;
            self.active_scene_add_entity_fn = add_entity_fn;
            self.active_scene_clear_entities_fn = clear_entities_fn;
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

        /// Register a runtime-created entity with the active scene.
        pub fn addEntityToActiveScene(self: *Self, entity: Entity) void {
            if (self.active_scene_ptr) |ptr| if (self.active_scene_add_entity_fn) |add_fn| {
                add_fn(ptr, entity);
            };
        }

        /// Remove all entities from the active scene's entity list.
        /// Does NOT destroy ECS entities — caller handles that.
        pub fn clearActiveSceneEntities(self: *Self) void {
            if (self.active_scene_ptr) |ptr| if (self.active_scene_clear_entities_fn) |clear_fn| {
                clear_fn(ptr);
            };
        }

        /// Destroy all entities and visuals atomically, then reinitialize
        /// the ECS backend and renderer to a clean state. The nested entity
        /// arena is also reset. Scene tracking (active_scene_ptr, etc.) is
        /// NOT affected — the scene remains active with an empty entity list.
        /// Call clearActiveSceneEntities() first if the scene's entity list
        /// should also be cleared.
        // ── World Management ─────────────────────────────────────

        /// Create a new named world. The world is inactive (stored in the map).
        /// Returns error.WorldAlreadyExists if the name is taken.
        pub fn createWorld(self: *Self, name: []const u8) !void {
            if (self.worlds.contains(name)) return error.WorldAlreadyExists;
            const duped = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(duped);
            const world = try self.allocator.create(World);
            errdefer {
                world.deinit();
                self.allocator.destroy(world);
            }
            world.* = World.init(self.allocator);
            try self.worlds.put(duped, world);
        }

        /// Destroy a named inactive world. Frees all its entities and visuals.
        pub fn destroyWorld(self: *Self, name: []const u8) void {
            if (self.worlds.fetchRemove(name)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
                self.allocator.free(kv.key);
            }
        }

        /// Swap the active world. The named world becomes active; the current
        /// active world is shelved into the map (if named) or destroyed (if unnamed).
        /// Verifies the target exists BEFORE modifying any state.
        pub fn setActiveWorld(self: *Self, name: []const u8) !void {
            // Remove target first — guarantees a free slot for shelving the current world
            const kv = self.worlds.fetchRemove(name) orelse return error.WorldNotFound;

            // Shelve or destroy current active world
            if (self.active_world_name) |current_name| {
                // Named world — shelve into map (can't fail: we just freed a slot)
                self.worlds.put(current_name, self.active_world) catch @panic("OOM shelving world");
            } else {
                // Unnamed default world — destroy it
                self.active_world.deinit();
                self.allocator.destroy(self.active_world);
            }

            // Activate the named world
            self.active_world = kv.value;
            self.ecs_backend = &kv.value.ecs_backend;
            self.renderer = &kv.value.renderer;
            self.active_world_name = kv.key;
        }

        /// Rename an inactive world in the map.
        pub fn renameWorld(self: *Self, old_name: []const u8, new_name: []const u8) !void {
            if (self.worlds.contains(new_name)) return error.WorldAlreadyExists;

            // Dupe new name first (before removing) so failure is safe
            const duped = try self.allocator.dupe(u8, new_name);
            errdefer self.allocator.free(duped);

            if (self.worlds.fetchRemove(old_name)) |kv| {
                self.allocator.free(kv.key);
                self.worlds.put(duped, kv.value) catch {
                    // Restore old entry on failure
                    const restored_key = self.allocator.dupe(u8, old_name) catch @panic("OOM restoring world");
                    self.worlds.put(restored_key, kv.value) catch @panic("OOM restoring world");
                    self.allocator.free(duped);
                    return error.OutOfMemory;
                };
            } else {
                self.allocator.free(duped);
                return error.WorldNotFound;
            }
        }

        /// Get a pointer to an inactive world.
        pub fn getWorld(self: *Self, name: []const u8) ?*World {
            return self.worlds.get(name);
        }

        /// Get the name of the active world (null if unnamed/default).
        pub fn getActiveWorldName(self: *const Self) ?[]const u8 {
            return self.active_world_name;
        }

        /// Check if a world exists in the inactive map.
        pub fn worldExists(self: *const Self, name: []const u8) bool {
            return self.worlds.contains(name);
        }

        pub fn resetEcsBackend(self: *Self) void {
            // Tear down active world's fields (reverse of init order)
            self.gizmo_state.deinit(self.allocator);
            self.active_world.sprite_cache.deinit();
            // Clear renderer entity tracking but keep GPU textures loaded.
            // Textures are expensive to reload (embedded atlas data parsed at startup).
            self.active_world.renderer.clear();
            self.active_world.ecs_backend.deinit();
            _ = self.active_world.nested_entity_arena.reset(.retain_capacity);

            // Reinitialize ECS + sprite cache (but NOT renderer — textures preserved)
            self.active_world.ecs_backend = EcsImpl.init(self.allocator);
            self.active_world.sprite_cache = atlas_mod.SpriteCache.init(self.allocator);
            self.gizmo_state = gizmo_draws_mod.GizmoState(Entity).init(self.allocator);
            // Re-sync backward-compatible pointers
            self.ecs_backend = &self.active_world.ecs_backend;
            // Clear tombstones — old entity IDs are meaningless after ECS reset
            if (comptime is_debug) {
                self.tombstones = [_]?TombstoneEntry{null} ** tombstone_size;
                self.tombstone_cursor = 0;
            }
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
                self.active_scene_add_entity_fn = null;
                self.active_scene_clear_entities_fn = null;


                self.active_world.sprite_cache.clear();
                // Free nested entity array allocations from the outgoing scene
                _ = self.active_world.nested_entity_arena.reset(.retain_capacity);
            }
        }

        // ── Game Loop ─────────────────────────────────────────────

        pub fn quit(self: *Self) void {
            self.running = false;
        }

        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        // ── Time scale ──

        pub fn setTimeScale(self: *Self, scale: f32) void {
            self.time_scale = @max(0, scale);
        }

        pub fn getTimeScale(self: *const Self) f32 {
            return self.time_scale;
        }

        pub fn isPaused(self: *const Self) bool {
            return self.time_scale == 0;
        }

        pub fn pause(self: *Self) void {
            self.time_scale = 0;
        }

        pub fn resume_(self: *Self) void {
            self.time_scale = 1.0;
        }

        pub fn tick(self: *Self, dt: f32) void {
            const scaled_dt = dt * self.time_scale;

            // Drain any worker-decoded asset uploads onto the GPU.
            // Without this no acquired asset ever reaches `.ready`,
            // and the Phase 2 setScene gate (#458) spins forever in
            // its `not_ready` branch. Pump runs every frame even
            // when paused so loading screens keep filling the bar
            // through pause states.
            self.assets.pump();

            // Always run: logging, audio, input, renderer sync, gizmo reconciliation.
            // These must run even when paused so the game remains responsive.
            self.log.update(dt);
            Audio.update();
            Input.updateGestures(dt);
            self.resolveAtlasSprites();
            self.renderer.sync(EcsImpl, self.ecs_backend);

            // Reconcile gizmos for runtime-created entities
            if (self.gizmo_reconcile_fn) |reconcile_fn| {
                reconcile_fn(self);
            }

            // State changes must process even when paused (e.g. pause → menu).
            // Clear pending BEFORE setState so hooks can re-queue without being overwritten.
            if (self.pending_state_change) |new_state| {
                self.pending_state_change = null;
                self.setState(new_state);
            }

            // Scene changes must process even when paused (e.g. pause menu → new scene)
            if (self.pending_scene_change) |next_scene| {
                const atomic = self.pending_scene_atomic;
                defer {
                    self.allocator.free(next_scene);
                    self.pending_scene_change = null;
                    self.pending_scene_atomic = false;
                }
                if (atomic) {
                    self.setSceneAtomic(next_scene) catch {};
                } else {
                    self.setScene(next_scene) catch {};
                }
            }

            // Hot reload: re-trigger the current scene's loader
            if (self.hot_reload_dirty) {
                self.hot_reload_dirty = false;
                if (self.current_scene_name) |name| {
                    if (self.scenes.get(name)) |entry| {
                        self.unloadCurrentScene();
                        self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });
                        entry.loader_fn(self) catch {};
                        self.emitHook(.{ .scene_load = .{ .name = name } });
                    }
                }
            }

            // Paused: skip game logic but keep frame counter advancing
            if (scaled_dt == 0) {
                self.frame_number += 1;
                return;
            }

            self.emitHook(.{ .frame_start = .{ .frame_number = self.frame_number, .dt = scaled_dt } });

            if (self.active_scene_ptr) |scene_ptr| {
                if (self.active_scene_update_fn) |update_fn| {
                    update_fn(scene_ptr, scaled_dt);
                }
            }

            self.emitHook(.{ .frame_end = .{ .frame_number = self.frame_number, .dt = scaled_dt } });
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

        /// Set the screen height on the active world's renderer.
        pub fn setScreenHeight(self: *Self, height: f32) void {
            self.renderer.setScreenHeight(height);
        }

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
            const dims = self.queryTextureDims(tex_id);
            try self.atlas_manager.loadAtlasFromJson(name, json_path, id, dims);
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

        /// Load an atlas from embedded memory (PNG bytes + JSON content).
        /// Usage: game.loadAtlasFromMemory("bg", json_bytes, png_bytes, ".png");
        ///
        /// Convenience: `registerAtlasFromMemory` + `loadAtlasIfNeeded`.
        /// Still blocks the calling frame — the PNG decode now runs on
        /// the asset worker thread (Asset Streaming RFC #437), but this
        /// method pumps the catalog synchronously until the atlas is
        /// `.ready` so the surface behaviour matches the legacy eager
        /// path. Cold-start UX is unchanged by design — spreading the
        /// decode cost across frames is Phase 2's job (scene-manifest
        /// acquire, not this shim).
        const has_load_from_memory = @hasDecl(RenderImpl, "loadTextureFromMemory");
        pub const loadAtlasFromMemory = if (has_load_from_memory) loadAtlasFromMemoryImpl else @compileError("Renderer does not support loadTextureFromMemory");

        fn loadAtlasFromMemoryImpl(self: *Self, name: []const u8, json_content: []const u8, image_data: []const u8, file_type: [:0]const u8) !void {
            try self.registerAtlasFromMemoryImpl(name, json_content, image_data, file_type);
            _ = try self.loadAtlasIfNeededImpl(name);
        }

        /// Register an atlas in **deferred** mode: parse the JSON
        /// eagerly (cheap) but skip the PNG decode (expensive). The
        /// atlas is added to the manager with no `texture_id` and a
        /// `pending` block carrying the PNG byte slice. The first call
        /// to `loadAtlasIfNeeded(name)` decodes the PNG, uploads to
        /// the GPU, and promotes the atlas to "loaded".
        ///
        /// `image_data` must outlive the atlas — typically a slice
        /// from `@embedFile`, which lives forever. Pair this with
        /// `loadAtlasIfNeeded` from a loading-scene script to spread
        /// PNG decode cost across multiple frames instead of paying
        /// for everything in `init()`.
        ///
        /// Side effect (RFC #437 #443): the same name is registered on
        /// `self.assets` as a `.image` asset carrying the PNG bytes, so
        /// the pump-driven shim below can run the decode off-thread.
        /// Existing scene / script code that already registered the
        /// asset directly on the catalog — e.g. assembler-generated
        /// init code that walks the scene's `assets` manifest — is
        /// tolerated: `register` reports `AssetAlreadyRegistered` and
        /// we swallow that specific error.
        pub const registerAtlasFromMemory = if (has_load_from_memory) registerAtlasFromMemoryImpl else @compileError("Renderer does not support loadTextureFromMemory");

        fn registerAtlasFromMemoryImpl(self: *Self, name: []const u8, json_content: []const u8, image_data: []const u8, file_type: [:0]const u8) !void {
            // Keep the legacy TextureManager side-effects: parse JSON
            // eagerly so `findSprite` works after the catalog finishes
            // uploading, stash the `PendingImage` so `markPendingLoaded`
            // can derive the texture scale against the JSON's meta.size
            // once the shim learns the actual dims.
            try self.atlas_manager.registerPendingAtlas(name, json_content, image_data, file_type);

            // Mirror onto the catalog. Double-registration (e.g. when
            // the assembler's scene manifest code already registered
            // the same name on the catalog) is not an error: the
            // catalog is the source of truth for the PNG bytes, and
            // re-registering identical bytes is a no-op from the
            // loader's perspective.
            self.assets.register(name, .image, file_type, image_data) catch |err| switch (err) {
                error.AssetAlreadyRegistered => {},
                else => return err,
            };
        }

        /// Decode a previously-registered pending atlas if it hasn't
        /// already been loaded. No-op (returns `false`) when the atlas
        /// is already loaded — safe to call every frame from a loading
        /// loop. Returns `true` on the call that actually performed
        /// the decode, so a loading script can advance a progress
        /// counter.
        ///
        /// Implementation (RFC #437 §2): bumps the catalog refcount so
        /// the worker thread picks up the decode, then busy-pumps until
        /// the entry is `.ready` (happy path) or `lastError` is set
        /// (decode / upload failed). `std.Thread.yield()` between
        /// iterations keeps the loop cooperative on single-core
        /// targets. **The `pump()` call inside the loop is
        /// load-bearing** — without it the worker finishes the decode
        /// but the main thread never finalises the upload, and the
        /// loop spins forever. See the "deadlock regression" test in
        /// `test/asset_streaming_shim_test.zig`.
        pub const loadAtlasIfNeeded = if (has_load_from_memory) loadAtlasIfNeededImpl else @compileError("Renderer does not support loadTextureFromMemory");

        fn loadAtlasIfNeededImpl(self: *Self, name: []const u8) !bool {
            const atlas = self.atlas_manager.getAtlasMut(name) orelse return error.AtlasNotFound;
            if (atlas.isLoaded()) return false;

            // Bump refcount on the catalog. First acquire on a fresh
            // entry enqueues the decode; subsequent acquires just pin
            // the refcount so the zombie-drop path in `pump()` can't
            // rewind us while we are waiting for the upload to land.
            //
            // `errdefer release` guarantees the shim returns the
            // refcount on every failure path (lastError, missing
            // entry, wrong asset kind, markPendingLoaded error, …).
            // Without it, a failed load leaks a phantom refcount that
            // keeps the entry acquired forever — and since `acquire`
            // only re-enqueues on the 0→1 transition, a retry after
            // failure would just bump the leak without re-triggering
            // a decode.
            _ = try self.assets.acquire(name);
            // Mirror of the acquire above. Runs on any error path so
            // the catalog refcount stays consistent. On the happy path
            // — when `markPendingLoaded` succeeds and we `return true`
            // — the defer does NOT fire, intentionally leaving the
            // refcount at 1 to keep the loaded entry pinned in the
            // catalog (prevents the zombie-drop path from rewinding
            // the state back to `.registered` if Phase 2 ever calls
            // `release` for an unrelated scene transition).
            errdefer self.assets.release(name);

            // Busy-pump until the decode + upload complete OR the
            // catalog surfaces an error via `lastError`. Same-thread
            // async-under-the-hood, sync-at-the-surface: no visible
            // UX change from the legacy path that called
            // `renderer.loadTextureFromMemory` directly on the main
            // thread.
            //
            // Known limitation (pre-existing from #450's acquire
            // design): if the request ring was full when `acquire`
            // fired, the work request is dropped, state stays
            // `.registered`, refcount is bumped, and neither `pump()`
            // nor any other layer re-enqueues it. This loop would
            // then spin forever. Not reachable on current workloads
            // (64-slot ring vs single-digit asset counts), but a
            // follow-up should either make `acquire` fail on
            // QueueFull or add retry logic to `pump()`.
            while (!self.assets.isReady(name)) {
                if (self.assets.lastError(name)) |err| {
                    // Rewind .failed → .registered so the next
                    // loadAtlasIfNeeded retries the decode instead of
                    // returning the stale error forever. Without this,
                    // any decode/upload failure becomes permanent: the
                    // errdefer above drops refcount to 0, but state
                    // stays .failed, and `acquire` only re-enqueues
                    // from .registered. So the retry would hit the
                    // already-set lastError and immediately return
                    // the old error without re-triggering work — a
                    // regression from the legacy direct-decode path
                    // which simply re-attempted the call.
                    self.assets.resetFailed(name);
                    return err;
                }
                self.assets.pump();
                std.Thread.yield() catch {};
            }

            // Upload done — the catalog has a valid `UploadedResource`
            // for the entry. Pull the backend-assigned texture handle
            // out and seed the TextureManager's `RuntimeAtlas` so the
            // rest of the engine (sprite cache, `findSprite`, etc.)
            // can look the texture up through the legacy path.
            const entry = self.assets.entries.getPtr(name) orelse return error.AtlasNotFound;
            const resource = entry.resource orelse return error.AssetNotReady;
            const id: u32 = switch (resource) {
                .image => |t| t,
                else => return error.WrongAssetKind,
            };

            // The catalog-managed upload path does NOT populate the
            // renderer's texture side-table — the assembler-generated
            // adapter uploads directly to the GPU backend, bypassing
            // `renderer.loadTextureFromMemory`. `getTextureInfo` would
            // therefore return null for catalog-uploaded textures, so
            // `markPendingLoaded` gets `null` dims and falls back to
            // scale=1.0. Matches the legacy fallback behavior when the
            // renderer doesn't expose `getTextureInfo` at all. Atlases
            // that shipped a downscaled PNG and relied on automatic
            // texture_scale derivation will need an explicit workflow
            // once Phase 2 takes over the cold-start path — out of
            // scope for #443.
            try self.atlas_manager.markPendingLoaded(name, id, null);
            return true;
        }

        /// Whether an atlas's PNG has been decoded. Returns `false`
        /// for unregistered atlases too — both states mean "you can't
        /// use it yet". Used by loading scripts to decide which
        /// atlases still need a `loadAtlasIfNeeded` call.
        ///
        /// Reads from the `TextureManager` side, not the catalog: the
        /// atlas is only "loaded" from the engine's point of view once
        /// `markPendingLoaded` has populated the `RuntimeAtlas` with a
        /// real `texture_id`. A catalog entry that is `.ready` but has
        /// not yet been drained by `loadAtlasIfNeeded` is still
        /// considered "not loaded" for the legacy surface.
        pub fn isAtlasLoaded(self: *Self, name: []const u8) bool {
            const atlas = self.atlas_manager.getAtlas(name) orelse return false;
            return atlas.isLoaded();
        }

        /// Look up the actual pixel dimensions of a freshly-loaded
        /// texture, so the atlas loader can derive a scale against the
        /// JSON's logical `meta.size`. Returns null when the renderer
        /// doesn't expose a `getTextureInfo` accessor — the atlas
        /// loader then falls back to scale=1.0 (legacy behavior).
        ///
        /// Texture dims are clamped to `[0, max u32]` before the float
        /// → int cast so a malformed renderer that returns negative or
        /// NaN values can't trigger an `@intFromFloat` panic. Real
        /// renderers always return positive integers, so this is a
        /// belt-and-braces guard for buggy backend mocks.
        fn queryTextureDims(self: *Self, tex_id: anytype) ?atlas_mod.TextureManager.TextureDims {
            if (!@hasDecl(RenderImpl, "getTextureInfo")) return null;
            const info = self.renderer.getTextureInfo(tex_id) orelse return null;
            return .{
                .width = clampToU32(info.width),
                .height = clampToU32(info.height),
            };
        }

        fn clampToU32(v: f32) u32 {
            if (!std.math.isFinite(v) or v <= 0) return 0;
            // `@floatFromInt(maxInt(u32))` rounds *up* to 2^32 in f32
            // because the f32 mantissa is only 24 bits, so comparing
            // against it would let `@intFromFloat` see exactly 2^32 —
            // one above the u32 range, triggering UB / safety panic.
            // The largest f32 value strictly less than 2^32 is
            // 4_294_967_040 (= 2^32 - 2^8). Clamp to that.
            const max_safe: f32 = 4_294_967_040.0;
            if (v >= max_safe) return std.math.maxInt(u32);
            return @intFromFloat(v);
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
            return self.active_world.sprite_cache.lookup(entity_id, sprite_name, &self.atlas_manager);
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

                const misses_before = self.active_world.sprite_cache.misses;
                if (self.active_world.sprite_cache.lookup(@intCast(entity), sprite.sprite_name, &self.atlas_manager)) |result| {
                    // Only update and mark dirty on cache miss (new sprite or atlas changed)
                    if (self.active_world.sprite_cache.misses != misses_before) {
                        sprite.texture = @enumFromInt(result.texture_id);
                        // The atlas data is in the JSON's logical pixel
                        // grid. `texture_scale_*` maps that grid onto the
                        // actual texture pixels — `1.0` for the common
                        // case, `< 1` when the user shipped a downscaled
                        // PNG without re-running TexturePacker.
                        //
                        // Two distinct mappings are needed:
                        //
                        //   * The PHYSICAL atlas footprint (`sprite.x/y`,
                        //     `sprite.width/height`) is in texture-pixel
                        //     coordinates regardless of rotation. Each
                        //     axis scales independently, so x/width go
                        //     through `texture_scale_x` and y/height go
                        //     through `texture_scale_y`.
                        //
                        //   * The DISPLAY dimensions (`getWidth/Height`)
                        //     swap when the sprite was rotated 90° in the
                        //     atlas — that's the on-screen size. They
                        //     stay un-scaled.
                        //
                        // Mixing the two (multiplying `getWidth()` by
                        // `texture_scale_x`) is wrong for rotated sprites
                        // because `getWidth()` returns the post-rotation
                        // height — a vertical dimension scaled by a
                        // horizontal factor.
                        const phys_x: f32 = @floatFromInt(result.sprite.x);
                        const phys_y: f32 = @floatFromInt(result.sprite.y);
                        const phys_w: f32 = @floatFromInt(result.sprite.width);
                        const phys_h: f32 = @floatFromInt(result.sprite.height);
                        const display_w: f32 = @floatFromInt(result.sprite.getWidth());
                        const display_h: f32 = @floatFromInt(result.sprite.getHeight());
                        const scaled_w = phys_w * result.texture_scale_x;
                        const scaled_h = phys_h * result.texture_scale_y;
                        sprite.source_rect = .{
                            .x = phys_x * result.texture_scale_x,
                            .y = phys_y * result.texture_scale_y,
                            // `source_rect.width/height` are in the same
                            // post-rotation orientation that the renderer
                            // expects (matching `getWidth/Height`),
                            // so swap when the sprite was rotated.
                            .width = if (result.sprite.rotated) scaled_h else scaled_w,
                            .height = if (result.sprite.rotated) scaled_w else scaled_h,
                            .display_width = display_w,
                            .display_height = display_h,
                        };
                        self.renderer.markVisualDirty(entity);
                    }
                }
            }
        }

        // ── Accessors ─────────────────────────────────────────────

        pub fn getRenderer(self: *Self) *RenderImpl {
            return self.renderer;
        }

        pub fn getEcsBackend(self: *Self) *EcsImpl {
            return self.ecs_backend;
        }

        pub fn entityCount(self: *Self) usize {
            return @intCast(self.ecs_backend.entityCount());
        }
    };
}

/// Convenience: Game with custom hooks, StubRender + mock ECS
pub fn GameWith(comptime Hooks: type) type {
    const EmptyComponents = struct {
        pub fn has(comptime _: []const u8) bool { return false; }
        pub fn names() []const []const u8 { return &.{}; }
    };
    return GameConfig(
        core.StubRender(MockEcsBackend(u32).Entity),
        MockEcsBackend(u32),
        @import("input.zig").StubInput,
        @import("audio.zig").StubAudio,
        @import("gui.zig").StubGui,
        Hooks,
        core.StubLogSink,
        EmptyComponents,
        &.{}, // no gizmo categories
        void, // no game events
    );
}

/// Convenience: full mock game for testing
pub const Game = GameWith(void);
