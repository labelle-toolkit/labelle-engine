// Scene Loader — two-phase entity loading with reference resolution
//
// Ported from v1 scene/src/loader.zig + loader/entity_components.zig

const std = @import("std");
const labelle_core = @import("labelle-core");

const types = @import("types.zig");
const core_mod = @import("core.zig");
const gizmo_mod = @import("gizmo.zig");
const script_mod = @import("script.zig");
const entity_writer_mod = @import("entity_writer.zig");

const Position = labelle_core.Position;
const VisualType = labelle_core.VisualType;
const ScriptFns = script_mod.ScriptFns;
const isReference = types.isReference;
const extractRefInfo = types.extractRefInfo;
const getEntityId = types.getEntityId;
const ReferenceContext = types.ReferenceContext;
const GizmoComponent = gizmo_mod.GizmoComponent;
const Scene = core_mod.Scene;
const ParentComponent = core_mod.ParentComponent;
const ChildrenComponent = core_mod.ChildrenComponent;

/// Convert a comptime .zon tuple of strings to a `[]const []const u8` slice.
fn tupleToStringSlice(comptime tuple: anytype) []const []const u8 {
    const fields = std.meta.fields(@TypeOf(tuple));
    if (fields.len == 0) return &[_][]const u8{};
    comptime {
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            result[i] = @field(tuple, field.name);
        }
        const final = result;
        return &final;
    }
}

/// Scene loader — loads .zon scene data into the engine.
///
/// Parameterized by:
/// - GameType: from GameConfig(...), provides Entity type, Sprite/Shape components, ECS backend
/// - Prefabs: PrefabRegistry with .zon prefab definitions
/// - Components: ComponentRegistry mapping names to game-specific component types
/// - Scripts: ScriptRegistry mapping names to lifecycle functions (default: NoScripts)
///
/// Supports:
/// - Prefab entities with component merging (scene overrides prefab defaults)
/// - Inline entities with arbitrary components
/// - Script lifecycle (init/update/deinit)
/// - Entity lifecycle hooks (onUpdate/onDestroy from prefabs)
/// - Deep .zon coercion (structs, tagged unions, enums)
pub fn SceneLoader(
    comptime GameType: type,
    comptime Prefabs: type,
    comptime Components: type,
    comptime Scripts: type,
) type {
    return SceneLoaderWithGizmos(GameType, Prefabs, Components, Scripts, gizmo_mod.NoGizmos);
}

pub fn SceneLoaderWithGizmos(
    comptime GameType: type,
    comptime Prefabs: type,
    comptime Components: type,
    comptime Scripts: type,
    comptime GizmoReg: type,
) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;
    const SceneType = Scene(Entity);
    const EntityInstance = SceneType.EntityInstance;
    const RefCtx = ReferenceContext(Entity);
    const Gizmo = GizmoComponent(Entity);
    const Writer = entity_writer_mod.EntityWriter(GameType, Components);
    const Pos = struct { x: f32 = 0, y: f32 = 0 };
    const GizmoAttached = struct { _: u8 = 1 };

    return struct {
        /// Load a scene from comptime .zon data.
        ///
        /// Uses two-phase loading for entity references:
        /// - Phase 1: Create all entities, track by name/ID
        /// - Phase 2: Resolve entity references (.ref = .{ .entity = "name" })
        /// - Phase 2b: Resolve parent-child relationships (.parent = "name")
        pub fn load(comptime scene_data: anytype, game: *GameType, allocator: std.mem.Allocator) !SceneType {
            // Resolve scripts
            const script_fns = comptime if (@hasField(@TypeOf(scene_data), "scripts"))
                Scripts.getScriptFnsList(scene_data.scripts)
            else
                &[_]ScriptFns{};

            // Resolve gui_views (tuple of string literals → slice)
            const gui_view_names = comptime if (@hasField(@TypeOf(scene_data), "gui_views"))
                tupleToStringSlice(scene_data.gui_views)
            else
                &[_][]const u8{};

            var scene = SceneType.init(allocator, scene_data.name, script_fns, gui_view_names, @ptrCast(game), &gameDestroyEntity);
            errdefer scene.deinit();

            // Reference context for two-phase loading
            var ref_ctx = RefCtx.init(allocator);
            defer ref_ctx.deinit();

            // =============================================
            // PHASE 1: Create all entities, track by ID/name
            // =============================================
            comptime var entity_index: usize = 0;
            inline for (scene_data.entities) |entity_def| {
                const instance = loadEntity(entity_def, game, &ref_ctx);
                try scene.addEntity(instance);

                // Register entity by ID (auto-generated if not specified)
                const entity_id = comptime getEntityId(entity_def, entity_index);
                try ref_ctx.registerId(entity_id, instance.entity);

                // Also track named entities for name-based reference resolution
                if (@hasField(@TypeOf(entity_def), "name")) {
                    try ref_ctx.registerNamed(entity_def.name, instance.entity);
                    try scene.registerName(entity_def.name, instance.entity);
                }

                entity_index += 1;
            }

            // =============================================
            // PHASE 2: Resolve entity references
            // =============================================
            for (ref_ctx.pending_refs.items) |pending| {
                const resolved_entity = if (pending.is_self_ref)
                    pending.target_entity
                else
                    ref_ctx.resolve(pending.ref_key, pending.is_id_ref) orelse {
                        std.log.err("Entity reference not found: '{s}'", .{pending.ref_key});
                        continue;
                    };

                pending.resolve_callback(@ptrCast(&game.ecs_backend), pending.target_entity, resolved_entity);
            }

            // =============================================
            // PHASE 2b: Resolve parent-child relationships
            // =============================================
            for (ref_ctx.pending_parents.items) |pending| {
                const parent_entity = ref_ctx.resolveById(pending.parent_key) orelse
                    ref_ctx.resolveByName(pending.parent_key) orelse
                {
                    std.log.err("Parent '{s}' not found for child '{s}'", .{
                        pending.parent_key,
                        pending.child_name,
                    });
                    continue;
                };

                // Add parent component to child, children tracking to parent
                game.ecs_backend.addComponent(pending.child_entity, ParentComponent(Entity){
                    .entity = parent_entity,
                });

                // Update parent's children list
                if (game.ecs_backend.getComponent(parent_entity, ChildrenComponent(Entity))) |children| {
                    children.addChild(pending.child_entity);
                } else {
                    var children = ChildrenComponent(Entity){};
                    children.addChild(pending.child_entity);
                    game.ecs_backend.addComponent(parent_entity, children);
                }
            }

            return scene;
        }

        /// Type-erased wrapper for game.destroyEntityOnly — called by Scene.deinit
        /// to clean up non-persistent entities in the ECS on scene unload.
        /// Uses destroyEntityOnly (not destroyEntity) because the scene iterates
        /// all entities including children — recursive child destruction would double-free.
        fn gameDestroyEntity(game_ptr: *anyopaque, entity: Entity) void {
            const game: *GameType = @ptrCast(@alignCast(game_ptr));
            game.destroyEntityOnly(entity);
        }

        /// Returns a function pointer suitable for registerScene/registerSceneSimple.
        /// Wraps the comptime scene data into a `fn (*GameType) anyerror!void` loader.
        /// The Scene is heap-allocated and registered on the game via setActiveScene,
        /// which ensures update() runs each tick and deinit() runs on scene unload.
        pub fn sceneLoaderFn(comptime scene_data: anytype) fn (*GameType) anyerror!void {
            return struct {
                /// Script names from the scene's .scripts field.
                /// null if the scene doesn't define .scripts (no filtering).
                const scene_script_names: ?[]const []const u8 = if (@hasField(@TypeOf(scene_data), "scripts"))
                    tupleToStringSlice(scene_data.scripts)
                else
                    null;

                fn loader(game: *GameType) anyerror!void {
                    const scene = try load(scene_data, game, game.allocator);
                    const scene_ptr = try game.allocator.create(SceneType);
                    scene_ptr.* = scene;
                    game.setActiveScene(
                        @ptrCast(scene_ptr),
                        &sceneUpdate,
                        &sceneDeinit,
                        &sceneGetEntityByName,
                        scene_script_names,
                    );
                    game.gizmo_reconcile_fn = &gizmoReconcile;
                }

                fn sceneUpdate(ptr: *anyopaque, dt: f32) void {
                    const s: *SceneType = @ptrCast(@alignCast(ptr));
                    s.update(dt);
                }

                fn sceneDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    const s: *SceneType = @ptrCast(@alignCast(ptr));
                    s.deinit();
                    allocator.destroy(s);
                }

                fn sceneGetEntityByName(ptr: *anyopaque, name: []const u8) ?Entity {
                    const s: *const SceneType = @ptrCast(@alignCast(ptr));
                    return s.getEntityByName(name);
                }

                fn gizmoReconcile(game: *GameType) void {
                    reconcileGizmos(game);
                }
            }.loader;
        }

        /// Instantiate a prefab at runtime with a specific world position.
        pub fn instantiatePrefab(
            comptime prefab_name: []const u8,
            scene: *SceneType,
            game: *GameType,
            x: f32,
            y: f32,
        ) !Entity {
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found: " ++ prefab_name);
                }
            }

            const entity = game.createEntity();
            game.setPosition(entity, .{ .x = x, .y = y });

            var vtype: VisualType = .none;
            if (comptime Prefabs.hasComponents(prefab_name)) {
                vtype = addComponents(entity, game, comptime Prefabs.getComponents(prefab_name), null);
            }

            // Fire onReady for all components now that entity is fully assembled
            if (comptime Prefabs.hasComponents(prefab_name)) {
                fireOnReadyForComponents(entity, game, comptime Prefabs.getComponents(prefab_name));
            }

            try scene.addEntity(.{
                .entity = entity,
                .visual_type = vtype,
                .prefab_name = prefab_name,
            });

            return entity;
        }

        /// Reconcile gizmos: for each gizmo definition in the registry,
        /// find entities matching the gizmo's component rules that don't
        /// have gizmos yet and create gizmo entities for them.
        /// Supports `.match` (required components) and `.exclude` (forbidden
        /// components) fields in gizmo .zon files.
        /// Call this every frame (or after entity creation) to ensure
        /// runtime-created entities get gizmos automatically.
        pub fn reconcileGizmos(game: *GameType) void {
            inline for (GizmoReg.fields) |field| {
                reconcileForGizmo(game, field.name);
            }
        }

        fn reconcileForGizmo(game: *GameType, comptime gizmo_name: []const u8) void {
            const gizmo_data = comptime GizmoReg.get(gizmo_name);
            const GizmoData = @TypeOf(gizmo_data);
            const has_match = comptime @hasField(GizmoData, "match");
            const has_exclude = comptime @hasField(GizmoData, "exclude");

            // Check if this gizmo has a matching component in the registry
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

            // Determine primary component type for the view query
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

            if (count > 0) {
                std.log.info("[GizmoReconcile] {s}: {d} new entities", .{ gizmo_name, count });
            }

            for (buf[0..count]) |entity| {
                const pos = game.getPosition(entity);
                createGizmosForPrefab(gizmo_name, entity, game, .{ .x = pos.x, .y = pos.y });
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
            // Check additional required components (skip first, already filtered by view)
            if (has_match) {
                const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                inline for (match_fields[1..]) |f| {
                    const name = @field(gizmo_data.match, f.name);
                    const T = Components.getType(name);
                    if (game.ecs_backend.getComponent(entity, T) == null) return false;
                }
            }
            // Check no excluded components are present
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

        fn loadEntity(comptime entity_def: anytype, game: *GameType, ref_ctx: *RefCtx) EntityInstance {
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return loadPrefabEntity(entity_def, game, ref_ctx);
            }
            if (@hasField(@TypeOf(entity_def), "components")) {
                return loadComponentEntity(entity_def, game, ref_ctx);
            }
            @compileError("Entity must have .prefab or .components field");
        }

        fn loadPrefabEntity(comptime entity_def: anytype, game: *GameType, ref_ctx: *RefCtx) EntityInstance {
            const prefab_name = entity_def.prefab;
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found: " ++ prefab_name);
                }
            }

            const entity = game.createEntity();
            ref_ctx.current_entity = entity;

            const pos = comptime resolvePosition(entity_def);
            game.setPosition(entity, .{ .x = pos.x, .y = pos.y });

            // Queue parent if specified
            queueParentIfPresent(entity_def, entity, ref_ctx);

            var vtype: VisualType = .none;
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_comps = comptime Prefabs.getComponents(prefab_name);
                const scene_comps = comptime if (@hasField(@TypeOf(entity_def), "components"))
                    entity_def.components
                else
                    .{};

                vtype = addMergedComponents(entity, game, prefab_comps, scene_comps, ref_ctx);

                // Expand nested entity arrays: spawn child entities for component
                // fields that contain inline entity definitions (e.g. .workstations
                // in a Room component), then populate the parent's []const u64 field.
                // Uses scene overrides if present, otherwise prefab defaults.
                expandNestedEntityArraysForMerged(entity, game, prefab_comps, scene_comps, pos, ref_ctx);
            }

            // Gizmos are created by reconcileGizmos() based on component matching,
            // not during scene loading. This ensures uniform gizmo creation for both
            // scene-loaded and runtime-created entities.

            // Spawn children declared in the prefab
            if (comptime Prefabs.hasChildren(prefab_name)) {
                spawnPrefabChildren(comptime Prefabs.getChildren(prefab_name), entity, game, pos, ref_ctx);
            }

            // Spawn children declared in scene entity override
            if (@hasField(@TypeOf(entity_def), "children")) {
                spawnInlineChildren(entity_def.children, entity, game, pos, ref_ctx);
            }

            // Fire onReady for all components now that entity is fully assembled.
            // Use fireOnReadyMerged to avoid duplicate calls for components that
            // appear in both the prefab and the scene override.
            {
                const prefab_comps = comptime if (Prefabs.hasComponents(prefab_name)) Prefabs.getComponents(prefab_name) else .{};
                const scene_comps = comptime if (@hasField(@TypeOf(entity_def), "components")) entity_def.components else .{};
                fireOnReadyMerged(entity, game, prefab_comps, scene_comps);
            }

            return .{ .entity = entity, .visual_type = vtype, .prefab_name = prefab_name };
        }

        fn loadComponentEntity(comptime entity_def: anytype, game: *GameType, ref_ctx: *RefCtx) EntityInstance {
            const entity = game.createEntity();
            ref_ctx.current_entity = entity;

            const pos = comptime getPositionFromComponents(entity_def);
            game.setPosition(entity, .{ .x = pos.x, .y = pos.y });

            // Queue parent if specified
            queueParentIfPresent(entity_def, entity, ref_ctx);

            const vtype = addComponents(entity, game, entity_def.components, ref_ctx);

            // Expand nested entity arrays in inline component definitions
            expandNestedEntityArraysForComps(entity, game, entity_def.components, pos, ref_ctx);

            // Spawn children declared inline
            if (@hasField(@TypeOf(entity_def), "children")) {
                spawnInlineChildren(entity_def.children, entity, game, pos, ref_ctx);
            }

            // Fire onReady for all components now that entity is fully assembled
            fireOnReadyForComponents(entity, game, entity_def.components);

            return .{ .entity = entity, .visual_type = vtype };
        }

        // =====================================================================
        // Parent-child queueing
        // =====================================================================

        fn queueParentIfPresent(comptime entity_def: anytype, entity: Entity, ref_ctx: *RefCtx) void {
            if (@hasField(@TypeOf(entity_def), "parent")) {
                const child_name = comptime if (@hasField(@TypeOf(entity_def), "name"))
                    entity_def.name
                else if (@hasField(@TypeOf(entity_def), "id"))
                    entity_def.id
                else
                    "";
                ref_ctx.addPendingParent(.{
                    .child_entity = entity,
                    .parent_key = entity_def.parent,
                    .child_name = child_name,
                }) catch @panic("OOM");
            }
        }

        // =====================================================================
        // Position resolution
        // =====================================================================

        fn resolvePosition(comptime entity_def: anytype) Pos {
            // Scene-level override
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (@hasField(@TypeOf(entity_def.components), "Position")) {
                    return extractPos(entity_def.components.Position);
                }
            }
            // Prefab default
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                if (Prefabs.hasComponents(entity_def.prefab)) {
                    const pc = Prefabs.getComponents(entity_def.prefab);
                    if (@hasField(@TypeOf(pc), "Position")) {
                        return extractPos(pc.Position);
                    }
                }
            }
            return .{ .x = 0, .y = 0 };
        }

        fn getPositionFromComponents(comptime entity_def: anytype) Pos {
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (@hasField(@TypeOf(entity_def.components), "Position")) {
                    return extractPos(entity_def.components.Position);
                }
            }
            return .{ .x = 0, .y = 0 };
        }

        fn extractPos(comptime p: anytype) Pos {
            return .{
                .x = if (@hasField(@TypeOf(p), "x")) p.x else 0,
                .y = if (@hasField(@TypeOf(p), "y")) p.y else 0,
            };
        }

        // =====================================================================
        // Component addition — delegated to EntityWriter
        // =====================================================================

        fn addComponents(entity: Entity, game: *GameType, comptime comps: anytype, ref_ctx: ?*RefCtx) VisualType {
            return Writer.addComponents(entity, game, comps, ref_ctx);
        }

        fn addMergedComponents(
            entity: Entity,
            game: *GameType,
            comptime prefab_comps: anytype,
            comptime scene_comps: anytype,
            ref_ctx: ?*RefCtx,
        ) VisualType {
            return Writer.addMergedComponents(entity, game, prefab_comps, scene_comps, ref_ctx);
        }

        // =====================================================================
        // onReady firing — delegated to EntityWriter
        // =====================================================================

        fn fireOnReadyForComponents(entity: Entity, game: *GameType, comptime comps: anytype) void {
            Writer.fireOnReadyForComponents(entity, game, comps);
        }

        fn fireOnReadyMerged(entity: Entity, game: *GameType, comptime prefab_comps: anytype, comptime scene_comps: anytype) void {
            Writer.fireOnReadyMerged(entity, game, prefab_comps, scene_comps);
        }

        // =====================================================================
        // Nested entity array expansion
        // =====================================================================

        /// Expand nested entity arrays within a single set of components.
        /// Used for inline (non-prefab) entities.
        fn expandNestedEntityArraysForComps(
            entity: Entity,
            game: *GameType,
            comptime comps: anytype,
            parent_pos: Pos,
            ref_ctx: *RefCtx,
        ) void {
            inline for (@typeInfo(@TypeOf(comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    const comp_data = @field(comps, field.name);
                    if (comptime Writer.hasNestedEntityFields(T, comp_data)) {
                        expandFieldsForComponent(T, comp_data, entity, game, parent_pos, ref_ctx);
                    }
                }
            }
        }

        /// Expand nested entity arrays for merged prefab + scene components.
        /// Scene overrides take precedence over prefab defaults for the nested data.
        fn expandNestedEntityArraysForMerged(
            entity: Entity,
            game: *GameType,
            comptime prefab_comps: anytype,
            comptime scene_comps: anytype,
            parent_pos: Pos,
            ref_ctx: *RefCtx,
        ) void {
            // Process prefab components (use scene override if present)
            inline for (@typeInfo(@TypeOf(prefab_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    const has_override = comptime @hasField(@TypeOf(scene_comps), field.name);
                    const comp_data = comptime if (has_override) @field(scene_comps, field.name) else @field(prefab_comps, field.name);
                    if (comptime Writer.hasNestedEntityFields(T, comp_data)) {
                        expandFieldsForComponent(T, comp_data, entity, game, parent_pos, ref_ctx);
                    }
                }
            }

            // Process scene-only components (not in prefab)
            inline for (@typeInfo(@TypeOf(scene_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;
                if (comptime @hasField(@TypeOf(prefab_comps), field.name)) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    const comp_data = @field(scene_comps, field.name);
                    if (comptime Writer.hasNestedEntityFields(T, comp_data)) {
                        expandFieldsForComponent(T, comp_data, entity, game, parent_pos, ref_ctx);
                    }
                }
            }
        }

        /// For a single component type T with .zon data, find all fields that are
        /// nested entity arrays, spawn child entities, and update the parent's
        /// component with the child entity IDs.
        fn expandFieldsForComponent(
            comptime T: type,
            comptime comp_data: anytype,
            parent_entity: Entity,
            game: *GameType,
            parent_pos: Pos,
            ref_ctx: *RefCtx,
        ) void {
            const t_info = @typeInfo(T);
            if (t_info != .@"struct") return;

            inline for (t_info.@"struct".fields) |comp_field| {
                if (comp_field.type == []const u64 or comp_field.type == []const Entity) {
                    if (@hasField(@TypeOf(comp_data), comp_field.name)) {
                        const field_val = @field(comp_data, comp_field.name);
                        if (comptime Writer.isNestedEntityArray(field_val)) {
                            spawnNestedEntities(
                                T,
                                comp_field.name,
                                field_val,
                                parent_entity,
                                game,
                                parent_pos,
                                ref_ctx,
                            );
                        }
                    }
                }
            }
        }

        /// Spawn child entities from a nested entity array tuple and update the
        /// parent component's []const u64 / []const Entity field with child IDs.
        ///
        /// NOTE: The allocated child ID slice is owned by the component field and
        /// must be freed when the entity is destroyed. Currently this requires
        /// manual cleanup — a proper solution is a component deinit lifecycle
        /// hook in the ECS (see issue #111).
        fn spawnNestedEntities(
            comptime CompType: type,
            comptime field_name: []const u8,
            comptime nested_data: anytype,
            parent_entity: Entity,
            game: *GameType,
            parent_pos: Pos,
            ref_ctx: *RefCtx,
        ) void {
            const NestedInfo = @typeInfo(@TypeOf(nested_data));
            const count = NestedInfo.@"struct".fields.len;
            if (count == 0) return;

            // Determine which field type the parent uses
            const FieldType = @TypeOf(@field(@as(CompType, undefined), field_name));
            const ElemType = if (FieldType == []const u64) u64 else Entity;

            // Allocate child ID buffer from the game's nested entity arena
            // (freed on scene teardown, not per-entity)
            const ids = game.nested_entity_arena.allocator().alloc(ElemType, count) catch @panic("OOM");
            comptime var i: usize = 0;
            inline for (NestedInfo.@"struct".fields) |_| {
                const child_def = nested_data[i];
                const child_entity = spawnNestedChild(child_def, parent_entity, game, parent_pos, ref_ctx);
                ids[i] = if (ElemType == u64) entityToU64(child_entity) else child_entity;
                i += 1;
            }

            // Update the parent component's field with the child IDs
            if (game.ecs_backend.getComponent(parent_entity, CompType)) |comp| {
                @field(comp, field_name) = ids;
            }
        }

        /// Spawn a single child entity from a nested entity definition within a
        /// component's entity array field. Handles both prefab references and
        /// inline component definitions. Returns the created child entity.
        fn spawnNestedChild(
            comptime child_def: anytype,
            parent_entity: Entity,
            game: *GameType,
            parent_pos: Pos,
            ref_ctx: *RefCtx,
        ) Entity {
            const child_entity = game.createEntity();
            ref_ctx.current_entity = child_entity;

            // Resolve child position relative to parent
            const local_pos = comptime if (@hasField(@TypeOf(child_def), "prefab"))
                resolveChildPosition(child_def)
            else
                getPositionFromComponents(child_def);
            // Store accumulated world position so getPosition() returns world coords
            game.setPosition(child_entity, .{ .x = parent_pos.x + local_pos.x, .y = parent_pos.y + local_pos.y });

            // Add components
            if (@hasField(@TypeOf(child_def), "prefab")) {
                const child_prefab = child_def.prefab;
                comptime {
                    if (!Prefabs.has(child_prefab)) {
                        @compileError("Nested child prefab not found: " ++ child_prefab);
                    }
                }
                if (comptime Prefabs.hasComponents(child_prefab)) {
                    const prefab_comps = comptime Prefabs.getComponents(child_prefab);
                    const scene_comps = comptime if (@hasField(@TypeOf(child_def), "components"))
                        child_def.components
                    else
                        .{};
                    _ = addMergedComponents(child_entity, game, prefab_comps, scene_comps, ref_ctx);

                    // Expand nested entity arrays on the child (e.g. storages on a Workstation)
                    const child_world_pos_for_expand = Pos{ .x = parent_pos.x + local_pos.x, .y = parent_pos.y + local_pos.y };
                    expandNestedEntityArraysForMerged(child_entity, game, prefab_comps, scene_comps, child_world_pos_for_expand, ref_ctx);
                }

                // Recursively spawn grandchildren from prefab
                if (comptime Prefabs.hasChildren(child_prefab)) {
                    spawnPrefabChildren(comptime Prefabs.getChildren(child_prefab), child_entity, game, local_pos, ref_ctx);
                }
            } else if (@hasField(@TypeOf(child_def), "components")) {
                _ = addComponents(child_entity, game, child_def.components, ref_ctx);
            }

            // Recursively spawn inline grandchildren
            if (@hasField(@TypeOf(child_def), "children")) {
                spawnInlineChildren(child_def.children, child_entity, game, local_pos, ref_ctx);
            }

            // Fire onReady
            if (@hasField(@TypeOf(child_def), "prefab")) {
                const prefab_comps = comptime if (Prefabs.hasComponents(child_def.prefab)) Prefabs.getComponents(child_def.prefab) else .{};
                const scene_comps = comptime if (@hasField(@TypeOf(child_def), "components")) child_def.components else .{};
                fireOnReadyMerged(child_entity, game, prefab_comps, scene_comps);
            } else if (@hasField(@TypeOf(child_def), "components")) {
                fireOnReadyForComponents(child_entity, game, child_def.components);
            }

            // Register child for cascade destruction without setting Parent on the
            // child. setParent would cause the renderer's computeWorldTransform to
            // double-count positions (stored pos is already accumulated world coords).
            const ChildrenComp = ChildrenComponent(Entity);
            if (game.ecs_backend.getComponent(parent_entity, ChildrenComp)) |children_comp| {
                children_comp.addChild(child_entity);
            } else {
                var new_children = ChildrenComp{};
                new_children.addChild(child_entity);
                game.ecs_backend.addComponent(parent_entity, new_children);
            }

            // Register by name if present
            if (@hasField(@TypeOf(child_def), "name")) {
                ref_ctx.registerNamed(child_def.name, child_entity) catch {};
            }

            return child_entity;
        }

        fn entityToU64(entity: Entity) u64 {
            if (Entity == u32) return @intCast(entity);
            if (Entity == u64) return entity;
            if (@hasDecl(Entity, "toU64")) return entity.toU64();
            return @intCast(@as(u32, @bitCast(entity)));
        }

        // =====================================================================
        // Children spawning (prefab .children + scene inline .children)
        // =====================================================================

        /// Spawn children declared in a prefab's .children field.
        /// Each child can be a prefab reference or inline components.
        fn spawnPrefabChildren(comptime children_data: anytype, parent_entity: Entity, game: *GameType, parent_pos: Pos, ref_ctx: *RefCtx) void {
            inline for (children_data) |child_def| {
                spawnChildEntity(child_def, parent_entity, game, parent_pos, ref_ctx);
            }
        }

        /// Spawn children declared inline on a scene entity.
        fn spawnInlineChildren(comptime children_data: anytype, parent_entity: Entity, game: *GameType, parent_pos: Pos, ref_ctx: *RefCtx) void {
            inline for (children_data) |child_def| {
                spawnChildEntity(child_def, parent_entity, game, parent_pos, ref_ctx);
            }
        }

        /// Spawn a single child entity and parent it.
        fn spawnChildEntity(comptime child_def: anytype, parent_entity: Entity, game: *GameType, parent_pos: Pos, ref_ctx: *RefCtx) void {
            const child_entity = game.createEntity();
            ref_ctx.current_entity = child_entity;

            // Child position is local (relative to parent)
            const local_pos = comptime if (@hasField(@TypeOf(child_def), "prefab"))
                resolveChildPosition(child_def)
            else
                getPositionFromComponents(child_def);
            game.setPosition(child_entity, .{ .x = local_pos.x, .y = local_pos.y });
            _ = parent_pos;

            // Add components
            if (@hasField(@TypeOf(child_def), "prefab")) {
                const child_prefab = child_def.prefab;
                comptime {
                    if (!Prefabs.has(child_prefab)) {
                        @compileError("Child prefab not found: " ++ child_prefab);
                    }
                }
                if (comptime Prefabs.hasComponents(child_prefab)) {
                    const prefab_comps = comptime Prefabs.getComponents(child_prefab);
                    const scene_comps = comptime if (@hasField(@TypeOf(child_def), "components"))
                        child_def.components
                    else
                        .{};
                    _ = addMergedComponents(child_entity, game, prefab_comps, scene_comps, ref_ctx);
                }

                // Recursively spawn grandchildren from prefab
                if (comptime Prefabs.hasChildren(child_prefab)) {
                    spawnPrefabChildren(comptime Prefabs.getChildren(child_prefab), child_entity, game, local_pos, ref_ctx);
                }
            } else if (@hasField(@TypeOf(child_def), "components")) {
                _ = addComponents(child_entity, game, child_def.components, ref_ctx);
            }

            // Recursively spawn inline grandchildren
            if (@hasField(@TypeOf(child_def), "children")) {
                spawnInlineChildren(child_def.children, child_entity, game, local_pos, ref_ctx);
            }

            // Fire onReady for all components now that child entity is fully assembled.
            // Use fireOnReadyMerged for prefab children to avoid duplicate calls
            // for components that appear in both the prefab and the scene override.
            if (@hasField(@TypeOf(child_def), "prefab")) {
                const prefab_comps = comptime if (Prefabs.hasComponents(child_def.prefab)) Prefabs.getComponents(child_def.prefab) else .{};
                const scene_comps = comptime if (@hasField(@TypeOf(child_def), "components")) child_def.components else .{};
                fireOnReadyMerged(child_entity, game, prefab_comps, scene_comps);
            } else if (@hasField(@TypeOf(child_def), "components")) {
                fireOnReadyForComponents(child_entity, game, child_def.components);
            }

            // Wire parent-child relationship
            game.setParent(child_entity, parent_entity, .{});

            // Register by name if present
            if (@hasField(@TypeOf(child_def), "name")) {
                ref_ctx.registerNamed(child_def.name, child_entity) catch {};
            }
        }

        fn resolveChildPosition(comptime child_def: anytype) Pos {
            // Scene-level override first
            if (@hasField(@TypeOf(child_def), "components")) {
                if (@hasField(@TypeOf(child_def.components), "Position")) {
                    return extractPos(child_def.components.Position);
                }
            }
            // Then prefab default
            if (@hasField(@TypeOf(child_def), "prefab")) {
                if (Prefabs.hasComponents(child_def.prefab)) {
                    const pc = Prefabs.getComponents(child_def.prefab);
                    if (@hasField(@TypeOf(pc), "Position")) {
                        return extractPos(pc.Position);
                    }
                }
            }
            return .{ .x = 0, .y = 0 };
        }

        // =====================================================================
        // Gizmo creation
        // =====================================================================

        fn createGizmosForPrefab(comptime prefab_name: []const u8, entity: Entity, game: *GameType, pos: Pos) void {
            if (comptime GizmoReg.has(prefab_name)) {
                if (comptime GizmoReg.getEntityGizmos(prefab_name)) |gizmos| {
                    createGizmoEntities(gizmos, entity, game, pos);
                }
                if (!game.ecs_backend.hasComponent(entity, GizmoAttached)) {
                    game.ecs_backend.addComponent(entity, GizmoAttached{});
                }
            }
        }

        fn createGizmoEntities(comptime gizmos_data: anytype, parent_entity: Entity, game: *GameType, parent_pos: Pos) void {
            inline for (@typeInfo(@TypeOf(gizmos_data)).@"struct".fields) |field| {
                const gizmo_data = @field(gizmos_data, field.name);

                const gizmo_entity = game.createEntity();

                // Get offset from gizmo data
                const offset_x: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "x")) gizmo_data.x else 0;
                const offset_y: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "y")) gizmo_data.y else 0;

                // Add Gizmo marker component
                game.ecs_backend.addComponent(gizmo_entity, Gizmo{
                    .parent_entity = parent_entity,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                });

                // Set position relative to parent
                game.setPosition(gizmo_entity, .{
                    .x = parent_pos.x + offset_x,
                    .y = parent_pos.y + offset_y,
                });

                // Add the visual component (Shape, Sprite, etc.)
                // Gizmo entities should be in the world layer so they render
                // in world-space with the camera transform.
                if (comptime std.mem.eql(u8, field.name, "Shape")) {
                    var shape = coerce(Shape, gizmo_data);
                    if (comptime @hasField(@TypeOf(shape.layer), "world"))
                        shape.layer = .world;
                    game.addShape(gizmo_entity, shape);
                } else if (comptime std.mem.eql(u8, field.name, "Sprite")) {
                    var sprite = coerce(Sprite, gizmo_data);
                    if (comptime @hasField(@TypeOf(sprite.layer), "world"))
                        sprite.layer = .world;
                    game.addSprite(gizmo_entity, sprite);
                }
            }
        }

        // =====================================================================
        // Visual type detection
        // =====================================================================

        fn getVisualTypeFromComponents(comptime components: anytype) VisualType {
            if (@hasField(@TypeOf(components), "Sprite")) return .sprite;
            if (@hasField(@TypeOf(components), "Shape")) return .shape;
            return .none;
        }

        fn getVisualTypeFromPrefab(comptime prefab_name: []const u8) VisualType {
            if (!Prefabs.hasComponents(prefab_name)) return .none;
            return getVisualTypeFromComponents(Prefabs.getComponents(prefab_name));
        }

        // =====================================================================
        // Deep .zon coercion — delegated to EntityWriter
        // =====================================================================

        fn coerce(comptime T: type, comptime zon_val: anytype) T {
            return Writer.coerce(T, zon_val);
        }

        fn merge(comptime T: type, comptime base: anytype, comptime overlay: anytype) T {
            return Writer.merge(T, base, overlay);
        }
    };
}

/// Convenience: SceneLoader without scripts.
pub fn SimpleSceneLoader(comptime GameType: type, comptime Prefabs: type, comptime Components: type) type {
    const NoScripts = script_mod.NoScripts;
    return SceneLoader(GameType, Prefabs, Components, NoScripts);
}


