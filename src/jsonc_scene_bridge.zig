/// Runtime JSONC scene bridge — loads JSONC scene files into the ECS.
///
/// This file is the public entry point. After the slice-by-slice
/// extraction in #495, the actual implementation now lives in
/// `src/jsonc/`:
///
///   - `deserializer.zig`     — Value → Zig-struct mapping
///   - `ref_resolver.zig`     — `@ref` two-pass resolution
///   - `on_ready.zig`         — onReady / postLoad firing
///   - `prefab_cache.zig`     — prefab cache + init helpers
///   - `component_apply.zig`  — component application + entity-array
///                              filtering
///   - `scene_loader.zig`     — recursive scene/entity walker (the
///                              meat of the bridge)
///
/// `JsoncSceneBridge` itself is now a thin shell that just re-exports
/// the three public load entry points from `SceneLoader`.
/// `JsoncSceneBridgeWithGizmos` adds gizmo reconciliation on top.
const std = @import("std");
const core = @import("labelle-core");
const scene_mod = @import("scene");
const gizmo_mod = scene_mod.gizmo;

const scene_loader_mod = @import("jsonc/scene_loader.zig");

/// Create a JSONC scene loader parameterized by game and component
/// types. `Components` is a
/// `ComponentRegistry`/`ComponentRegistryWithPlugins` type with
/// `has` / `getType` / `names`.
pub fn JsoncSceneBridge(comptime GameType: type, comptime Components: type) type {
    const Loader = scene_loader_mod.SceneLoader(GameType, Components);
    return struct {
        pub const loadScene = Loader.loadScene;
        pub const loadSceneFromSource = Loader.loadSceneFromSource;
        pub const addEmbeddedPrefab = Loader.addEmbeddedPrefab;
    };
}

/// JSONC scene bridge with gizmo reconciliation. Wraps
/// `JsoncSceneBridge` with a per-frame `reconcileGizmos` that
/// instantiates declarative `gizmos/*.zon` shapes as ECS children.
pub fn JsoncSceneBridgeWithGizmos(
    comptime GameType: type,
    comptime Components: type,
    comptime GizmoReg: type,
) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;
    const Gizmo = core.GizmoComponent(Entity);
    const Writer = scene_mod.EntityWriter(GameType, Components);
    const GizmoAttached = struct { _: u8 = 1 };
    // Tags a gizmo entity whose `visible` flag was force-flipped to
    // `false` by `syncGizmoVisibility` because the global toggle is
    // off. On toggle-on, only entities carrying this marker get
    // their visibility restored — author-set
    // `visible = false` (declared in a `gizmos/*.zon`) stays
    // hidden across toggles, matching the principle of least
    // surprise that an explicit declaration outranks the global
    // override.
    const GizmoForcedHidden = struct { _: u8 = 1 };
    const BaseBridge = JsoncSceneBridge(GameType, Components);

    return struct {
        /// Load a JSONC scene file and set up gizmo reconciliation.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            try BaseBridge.loadScene(game, scene_path, prefab_dir);
            game.gizmo_reconcile_fn = &reconcileGizmos;
        }

        /// Load a scene from an in-memory JSONC source string and set up gizmo reconciliation.
        pub fn loadSceneFromSource(game: *GameType, source: []const u8, prefab_dir: []const u8) !void {
            try BaseBridge.loadSceneFromSource(game, source, prefab_dir);
            game.gizmo_reconcile_fn = &reconcileGizmos;
        }

        /// Pre-load a prefab from embedded JSONC source. Delegates to BaseBridge.
        pub fn addEmbeddedPrefab(game: *GameType, name: []const u8, source: []const u8, prefab_dir: []const u8) !void {
            return BaseBridge.addEmbeddedPrefab(game, name, source, prefab_dir);
        }

        /// Per-frame gizmo reconciliation.
        ///
        /// Always runs the per-gizmo create pass (so newly-spawned
        /// matching entities still get their gizmo children), then
        /// syncs every gizmo entity's `visible` flag to the global
        /// `setGizmosEnabled` state. Toggling `G` flips visibility
        /// on all spawned gizmos in one frame — no entity churn,
        /// no resurrection cost. See labelle-engine#493.
        pub fn reconcileGizmos(game: *GameType) void {
            inline for (GizmoReg.fields) |field| {
                reconcileForGizmo(game, field.name);
            }
            syncGizmoVisibility(game);
        }

        /// Bring every Gizmo-tagged entity's `Shape` / `Sprite`
        /// visibility in sync with `gizmos_enabled`.
        ///
        /// Idempotent and self-narrowing: the view filter
        /// (`GizmoForcedHidden` excluded when disabled, included
        /// when enabled) means steady-state frames hit a view that
        /// returns zero entities, so the cost collapses to a
        /// view-setup + zero iterations once the transition has
        /// settled. That's why this can run unconditionally
        /// without a `last_gizmos_enabled` gate — and why no
        /// per-bridge static state survives across `Game.init` /
        /// `deinit` cycles.
        ///
        /// On disable: hide every currently-visible gizmo and tag
        /// it with `GizmoForcedHidden`. Gizmos already hidden
        /// (author-set `visible = false`) are left alone — no
        /// marker added.
        ///
        /// On enable: only unhide entities carrying the marker, so
        /// author-set hidden gizmos stay hidden across toggle
        /// cycles. The marker is removed once visibility is
        /// restored.
        fn syncGizmoVisibility(game: *GameType) void {
            const target = game.isGizmosEnabled();

            // Gather first, then mutate. Modifying components
            // mid-iteration on a view filtered by those same
            // components is asking for trouble across backends,
            // and we add/remove `GizmoForcedHidden` here which is
            // exactly what each branch's view filters on.
            //
            // ArrayList over a fixed-size buffer because a hard
            // cap silently strands gizmos beyond it. Capacity
            // grows with the count of entities currently in the
            // wrong state for this transition; once steady, the
            // list stays empty.
            var pending: std.ArrayList(Entity) = .{};
            defer pending.deinit(game.allocator);

            if (target) {
                var v = game.ecs_backend.view(.{ Gizmo, GizmoForcedHidden }, .{});
                defer v.deinit();
                while (v.next()) |entity| {
                    pending.append(game.allocator, entity) catch return;
                }
                for (pending.items) |entity| {
                    var dirty = false;
                    if (game.ecs_backend.getComponent(entity, Shape)) |shape| {
                        if (!shape.visible) {
                            shape.visible = true;
                            dirty = true;
                        }
                    }
                    if (game.ecs_backend.getComponent(entity, Sprite)) |sprite| {
                        if (!sprite.visible) {
                            sprite.visible = true;
                            dirty = true;
                        }
                    }
                    game.ecs_backend.removeComponent(entity, GizmoForcedHidden);
                    if (dirty) game.renderer.markVisualDirty(entity);
                }
            } else {
                var v = game.ecs_backend.view(.{Gizmo}, .{GizmoForcedHidden});
                defer v.deinit();
                while (v.next()) |entity| {
                    pending.append(game.allocator, entity) catch return;
                }
                for (pending.items) |entity| {
                    var forced = false;
                    if (game.ecs_backend.getComponent(entity, Shape)) |shape| {
                        if (shape.visible) {
                            shape.visible = false;
                            forced = true;
                        }
                    }
                    if (game.ecs_backend.getComponent(entity, Sprite)) |sprite| {
                        if (sprite.visible) {
                            sprite.visible = false;
                            forced = true;
                        }
                    }
                    if (forced) {
                        game.ecs_backend.addComponent(entity, GizmoForcedHidden{});
                        game.renderer.markVisualDirty(entity);
                    }
                }
            }
        }

        fn reconcileForGizmo(game: *GameType, comptime gizmo_name: []const u8) void {
            const gizmo_data = comptime GizmoReg.get(gizmo_name);
            const GizmoData = @TypeOf(gizmo_data);
            const has_match = comptime @hasField(GizmoData, "match");
            const has_exclude = comptime @hasField(GizmoData, "exclude");

            const has_primary = comptime blk: {
                if (has_match) {
                    const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                    if (match_fields.len == 0) @compileError("Gizmo '" ++ gizmo_name ++ "' has empty .match");
                    const first_name = @field(gizmo_data.match, match_fields[0].name);
                    if (!Components.has(first_name)) @compileError("Gizmo '" ++ gizmo_name ++ "' matches '" ++ first_name ++ "' not in ComponentRegistry");
                    break :blk true;
                } else {
                    const component_name = gizmo_mod.snakeToPascal(gizmo_name);
                    break :blk Components.has(component_name);
                }
            };

            if (!has_primary) return;

            const PrimaryType = comptime blk: {
                if (has_match) {
                    const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                    const first_name = @field(gizmo_data.match, match_fields[0].name);
                    break :blk Components.getType(first_name);
                } else {
                    break :blk Components.getType(gizmo_mod.snakeToPascal(gizmo_name));
                }
            };

            var buf: [64]Entity = undefined;
            var count: usize = 0;

            {
                var v = game.ecs_backend.view(.{PrimaryType}, .{GizmoAttached});
                while (v.next()) |entity| {
                    if (count < buf.len and matchesGizmoRules(entity, game, gizmo_data, has_match, has_exclude)) {
                        buf[count] = entity;
                        count += 1;
                    }
                }
                v.deinit();
            }

            for (buf[0..count]) |entity| {
                const pos = game.getPosition(entity);
                createGizmosForName(gizmo_name, entity, game, .{ .x = pos.x, .y = pos.y });
                game.ecs_backend.addComponent(entity, GizmoAttached{});
            }
        }

        fn matchesGizmoRules(
            entity: Entity,
            game: *GameType,
            comptime gizmo_data: anytype,
            comptime has_match: bool,
            comptime has_exclude: bool,
        ) bool {
            if (has_match) {
                const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                inline for (match_fields[1..]) |f| {
                    const name = @field(gizmo_data.match, f.name);
                    const T = Components.getType(name);
                    if (game.ecs_backend.getComponent(entity, T) == null) return false;
                }
            }
            if (has_exclude) {
                const exclude_fields = @typeInfo(@TypeOf(gizmo_data.exclude)).@"struct".fields;
                inline for (exclude_fields) |f| {
                    const name = @field(gizmo_data.exclude, f.name);
                    const T = Components.getType(name);
                    if (game.ecs_backend.getComponent(entity, T) != null) return false;
                }
            }
            return true;
        }

        fn createGizmosForName(comptime gizmo_name: []const u8, entity: Entity, game: *GameType, parent_pos: struct { x: f32 = 0, y: f32 = 0 }) void {
            if (comptime GizmoReg.has(gizmo_name)) {
                if (comptime GizmoReg.getEntityGizmos(gizmo_name)) |gizmos| {
                    createGizmoEntities(gizmos, entity, game, parent_pos);
                }
            }
        }

        fn createGizmoEntities(comptime gizmos_data: anytype, parent_entity: Entity, game: *GameType, parent_pos: anytype) void {
            inline for (@typeInfo(@TypeOf(gizmos_data)).@"struct".fields) |field| {
                const gizmo_data = @field(gizmos_data, field.name);

                const gizmo_entity = game.createEntity();
                game.trackSceneEntity(gizmo_entity);

                const offset_x: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "x")) gizmo_data.x else 0;
                const offset_y: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "y")) gizmo_data.y else 0;

                game.ecs_backend.addComponent(gizmo_entity, Gizmo{
                    .parent_entity = parent_entity,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                });

                game.setPosition(gizmo_entity, .{
                    .x = parent_pos.x + offset_x,
                    .y = parent_pos.y + offset_y,
                });

                // Honor whatever `visible` the author wrote into
                // the gizmo `.zon` (or its struct default). When
                // gizmos are globally disabled at spawn time, only
                // flip an *author-shown* gizmo to hidden and tag
                // it with `GizmoForcedHidden` so the next enable
                // transition can restore it. Author-set
                // `visible = false` stays false and gets no
                // marker — `syncGizmoVisibility`'s enable pass
                // ignores it, matching the principle of least
                // surprise that an explicit declaration outranks
                // the global override.
                const initial_visible = game.isGizmosEnabled();
                var forced_hidden = false;

                if (comptime std.mem.eql(u8, field.name, "Shape")) {
                    var shape = Writer.coerce(Shape, gizmo_data);
                    if (comptime @hasField(@TypeOf(shape.layer), "world"))
                        shape.layer = .world;
                    if (!initial_visible and shape.visible) {
                        shape.visible = false;
                        forced_hidden = true;
                    }
                    game.addShape(gizmo_entity, shape);
                } else if (comptime std.mem.eql(u8, field.name, "Sprite")) {
                    var sprite = Writer.coerce(Sprite, gizmo_data);
                    if (comptime @hasField(@TypeOf(sprite.layer), "world"))
                        sprite.layer = .world;
                    if (!initial_visible and sprite.visible) {
                        sprite.visible = false;
                        forced_hidden = true;
                    }
                    game.addSprite(gizmo_entity, sprite);
                }

                if (forced_hidden) {
                    game.ecs_backend.addComponent(gizmo_entity, GizmoForcedHidden{});
                }
            }
        }
    };
}
