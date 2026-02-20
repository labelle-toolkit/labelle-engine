// Scene loader - loads scenes from comptime .zon data with comptime prefab registry
//
// Scene .zon format:
// .{
//     .name = "level1",
//     .scripts = .{ "gravity", "floating" },  // optional
//
//     // Camera configuration (optional) - two formats supported:
//     //
//     // 1. Single camera (configures primary camera):
//     .camera = .{ .x = 0, .y = 0, .zoom = 1.0 },
//
//     // 2. Named cameras (for split-screen/multi-camera):
//     .cameras = .{
//         .main = .{ .x = 0, .y = 0, .zoom = 1.0 },      // camera 0 (primary)
//         .player2 = .{ .x = 100, .y = 0, .zoom = 1.0 }, // camera 1
//         .minimap = .{ .x = 0, .y = 0, .zoom = 0.25 },  // camera 2
//     },
//
//     .entities = .{
//         // Prefab entities with position in .components:
//         .{ .prefab = "player", .components = .{ .Position = .{ .x = 400, .y = 300 } } },
//         .{ .prefab = "player", .pivot = .bottom_center },  // pivot override, position defaults to (0,0)
//         .{ .prefab = "background" },
//         // Shape entities (Position and Shape in .components):
//         .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Shape = .{ .shape = .{ .circle = .{ .radius = 50 } }, .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } } },
//         .{ .components = .{ .Position = .{ .x = 200, .y = 200 }, .Shape = .{ .shape = .{ .rectangle = .{ .width = 100, .height = 50 } } } } },
//         // Sprite entities with position in .components:
//         .{ .components = .{ .Position = .{ .x = 300, .y = 150 }, .Sprite = .{ .name = "gem.png" }, .Health = .{ .current = 50 } } },
//         // Data-only entities (no visual):
//         .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Health = .{ .current = 100 } } },
//     },
// }
//
// Parent Reference Convention (RFC #169):
// When creating nested entities inside a component field (e.g., Workstation.output_storages),
// the loader automatically populates parent reference fields using a naming convention:
// - Look for a field matching the parent component's type name (lowercased)
// - If found, set that field to the parent entity
//
// Example:
//   const Storage = struct {
//       role: Role,
//       workstation: Entity = Entity.invalid,  // Auto-populated
//   };
//
//   .Workstation = .{
//       .output_storages = .{
//           .{ .components = .{ .Storage = .{ .role = .ios } } },
//       },
//   }
//   // Engine sets Storage.workstation = parent workstation entity
//
// onReady Callback:
// Components can define an onReady callback that fires after the entire entity
// hierarchy is complete (all siblings exist, parent's entity lists populated):
//
//   pub fn onReady(payload: engine.ComponentPayload) void {
//       // Safe to access parent and siblings here
//   }
//
// Pivot values: .center, .top_left, .top_center, .top_right, .center_left,
//               .center_right, .bottom_left, .bottom_center, .bottom_right, .custom
// For .custom pivot, also specify .pivot_x and .pivot_y (0.0-1.0)

const std = @import("std");
const ecs = @import("ecs");
const zon = @import("../../core/src/zon_coercion.zig");
const prefab_mod = @import("prefab.zig");
const core_mod = @import("core.zig");
const script_mod = @import("script.zig");
const game_mod = @import("../../engine/game.zig");
const loader_types = @import("loader/types.zig");
const entity_components_mod = @import("loader/entity_components.zig");

pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

pub const PrefabRegistry = prefab_mod.PrefabRegistry;
pub const Scene = core_mod.Scene;
pub const SceneContext = core_mod.SceneContext;
pub const EntityInstance = core_mod.EntityInstance;
pub const VisualType = core_mod.VisualType;
pub const Game = game_mod.Game;

// Re-export types from loader/types.zig
pub const ComponentPayload = loader_types.ComponentPayload;
pub const SceneCameraConfig = loader_types.SceneCameraConfig;
pub const CameraSlot = loader_types.CameraSlot;
pub const toLowercase = loader_types.toLowercase;

// Entity reference types (Issue #242)
pub const EntityRef = loader_types.EntityRef;
pub const ReferenceContext = loader_types.ReferenceContext;
pub const EntityMap = loader_types.EntityMap;
pub const PendingReference = loader_types.PendingReference;

// Internal types from loader/types.zig
const ReadyCallbackEntry = loader_types.ReadyCallbackEntry;
const ParentContext = loader_types.ParentContext;
const no_parent = loader_types.no_parent;
const Pos = loader_types.Pos;
const getFieldOrDefault = loader_types.getFieldOrDefault;
const getPositionFromComponents = loader_types.getPositionFromComponents;
const applyCameraConfig = loader_types.applyCameraConfig;

/// Scene loader that combines .zon scene data with comptime prefab and component/script registries
pub fn SceneLoader(comptime Prefabs: type, comptime Components: type, comptime Scripts: type) type {
    // Get Position type from Components registry (must be registered)
    const Position = Components.getType("Position");

    // Entity creation and component resolution core (extracted to loader/entity_components.zig)
    const Ops = entity_components_mod.EntityComponentOps(Prefabs, Components);

    return struct {
        /// Load a scene from comptime .zon data
        ///
        /// Uses two-phase loading for entity references (Issue #242):
        /// - Phase 1: Create all entities, track named entities
        /// - Phase 2: Resolve entity references (.ref = .{ .entity = "name" })
        pub fn load(
            comptime scene_data: anytype,
            ctx: SceneContext,
        ) !Scene {
            const game = ctx.game();

            // Register component lifecycle callbacks (onAdd, onSet, onRemove) for all components.
            // This must be called for each new registry/world (e.g., after scene changes).
            Components.registerCallbacks(game.getRegistry());

            // Get script lifecycle function bundles if scene has scripts defined
            const script_fns = comptime if (@hasField(@TypeOf(scene_data), "scripts"))
                Scripts.getScriptFnsList(scene_data.scripts)
            else
                &[_]script_mod.ScriptFns{};

            // Get GUI view names if scene has gui_views defined
            const gui_view_names = comptime if (@hasField(@TypeOf(scene_data), "gui_views"))
                zon.tupleToSlice([]const u8, scene_data.gui_views)
            else
                &[_][]const u8{};

            var scene = Scene.init(scene_data.name, script_fns, gui_view_names, ctx);
            errdefer scene.deinit();

            // Apply scene-level camera configuration if present
            // Priority: .cameras (named multi-camera) > .camera (single camera)
            if (@hasField(@TypeOf(scene_data), "cameras")) {
                // Named cameras for multi-camera setup
                const cameras = scene_data.cameras;

                inline for (@typeInfo(@TypeOf(cameras)).@"struct".fields) |field| {
                    const cam = @field(cameras, field.name);
                    const slot = comptime std.meta.stringToEnum(CameraSlot, field.name) orelse
                        @compileError("Unknown camera name: '" ++ field.name ++ "'. Valid names: main, player2, minimap, camera3");
                    applyCameraConfig(cam, game.getCameraAt(@intFromEnum(slot)));
                }
            } else if (@hasField(@TypeOf(scene_data), "camera")) {
                // Single camera (primary camera)
                applyCameraConfig(scene_data.camera, game.getCamera());
            }

            // Queue for onReady callbacks - fired after entire hierarchy is complete
            var ready_queue: std.ArrayListUnmanaged(ReadyCallbackEntry) = .{};
            defer ready_queue.deinit(game.allocator);

            // Reference context for two-phase loading (Issue #242)
            var ref_ctx = loader_types.ReferenceContext.init(game.allocator);
            defer ref_ctx.deinit();

            // ============================================
            // PHASE 1: Create all entities, track by ID and name
            // ============================================
            comptime var entity_index: usize = 0;
            inline for (scene_data.entities) |entity_def| {
                const instance = try loadEntity(entity_def, ctx, &scene, &ready_queue, &ref_ctx);
                try scene.addEntity(instance);

                // Register entity by ID (auto-generated if not specified)
                const entity_id = comptime zon.getEntityId(entity_def, entity_index);
                try ref_ctx.registerId(entity_id, instance.entity);

                // Also track named entities for name-based reference resolution
                if (@hasField(@TypeOf(entity_def), "name")) {
                    try ref_ctx.registerNamed(entity_def.name, instance.entity);
                }

                entity_index += 1;
            }

            // ============================================
            // PHASE 2: Resolve entity references
            // ============================================
            for (ref_ctx.pending_refs.items) |pending| {
                const resolved_entity = if (pending.is_self_ref)
                    pending.target_entity
                else
                    ref_ctx.resolve(pending.ref_key, pending.is_id_ref) orelse {
                        const ref_type = if (pending.is_id_ref) "id" else "name";
                        std.log.err("Entity reference not found: {s}='{s}'", .{
                            ref_type,
                            pending.ref_key,
                        });
                        continue;
                    };

                // Call the resolve callback to update the Entity field
                pending.resolve_callback(game.getRegistry(), pending.target_entity, resolved_entity);
            }

            // ============================================
            // PHASE 2b: Resolve parent-child relationships (RFC #243)
            // ============================================
            for (ref_ctx.pending_parents.items) |pending| {
                // Try ID first, then fall back to name for maximum flexibility
                const parent_entity = ref_ctx.resolveById(pending.parent_key) orelse
                    ref_ctx.resolveByName(pending.parent_key) orelse {
                    std.log.err("Parent '{s}' not found for child '{s}'", .{
                        pending.parent_key,
                        pending.child_name,
                    });
                    continue;
                };

                // Set up parent-child relationship with inheritance flags
                // Scene entities define position as local offsets, so no transform preservation needed
                game.hierarchy.setParentWithOptions(
                    pending.child_entity,
                    parent_entity,
                    pending.inherit_rotation,
                    pending.inherit_scale,
                ) catch |err| {
                    std.log.err("Failed to set parent '{s}' for child '{s}': {}", .{
                        pending.parent_key,
                        pending.child_name,
                        err,
                    });
                };
            }

            // Fire all onReady callbacks after hierarchy is complete (RFC #169)
            const game_ptr = ecs.getGamePtr() orelse {
                // Game pointer not set - skip onReady callbacks
                // This shouldn't happen in normal usage since Game.fixPointers sets it
                return scene;
            };
            for (ready_queue.items) |entry| {
                entry.callback(.{
                    .entity_id = ecs.entityToU64(entry.entity),
                    .game_ptr = game_ptr,
                });
            }

            return scene;
        }

        /// Instantiate a prefab at runtime with a specific world position.
        /// Returns the created entity and adds it to the scene.
        /// Uses uniform component handling - visual components are registered via onAdd callbacks.
        ///
        /// Usage (where Loader = SceneLoader(Prefabs, Components, Scripts)):
        ///   const entity = try Loader.instantiatePrefab("player", &scene, ctx, 100, 200);
        pub fn instantiatePrefab(
            comptime prefab_name: []const u8,
            scene: *Scene,
            ctx: SceneContext,
            x: f32,
            y: f32,
        ) !Entity {
            // Verify prefab exists at compile time
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found: " ++ prefab_name);
                }
            }

            const game = ctx.game();

            // Create ECS entity
            const entity = game.createEntity();

            // Add Position component
            game.getRegistry().addComponent(entity, Position{ .x = x, .y = y });

            // Queue for onReady callbacks
            var ready_queue: std.ArrayListUnmanaged(ReadyCallbackEntry) = .{};
            defer ready_queue.deinit(game.allocator);

            // Add all components from prefab (excluding Position which we already handled)
            // Visual components (Sprite, Shape, Text) are registered with pipeline via onAdd callbacks
            // Note: Runtime instantiation doesn't support entity references (no ref_ctx)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try Ops.addComponentsExcluding(game, scene, entity, Prefabs.getComponents(prefab_name), x, y, .{"Position"}, no_parent, &ready_queue, null);
            }

            // Add entity to scene
            try scene.addEntity(.{
                .entity = entity,
                .visual_type = comptime Ops.getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            });

            // Fire onReady callbacks after hierarchy is complete
            if (ecs.getGamePtr()) |game_ptr| {
                for (ready_queue.items) |entry| {
                    entry.callback(.{
                        .entity_id = ecs.entityToU64(entry.entity),
                        .game_ptr = game_ptr,
                    });
                }
            }

            return entity;
        }

        /// Load a single entity from its definition.
        /// Visual components (Sprite, Shape, Text) are handled uniformly through
        /// addComponentsExcluding, with their onAdd callbacks handling pipeline registration.
        fn loadEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: *loader_types.ReferenceContext,
        ) !EntityInstance {
            // Check if this references a prefab
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try loadPrefabEntity(entity_def, ctx, scene, ready_queue, ref_ctx);
            }

            // Inline entity with components
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try loadComponentEntity(entity_def, ctx, scene, ready_queue, ref_ctx);
            }

            @compileError("Entity must have .prefab or .components field");
        }

        /// Queue a parent-child relationship if .parent field is present on the entity definition.
        /// Tries ID resolution first, then falls back to name resolution.
        fn queueParentIfPresent(
            comptime entity_def: anytype,
            entity: Entity,
            ref_ctx: *loader_types.ReferenceContext,
        ) !void {
            if (@hasField(@TypeOf(entity_def), "parent")) {
                const child_name = if (@hasField(@TypeOf(entity_def), "name"))
                    entity_def.name
                else if (@hasField(@TypeOf(entity_def), "id"))
                    entity_def.id
                else
                    "";
                try ref_ctx.addPendingParent(.{
                    .child_entity = entity,
                    .parent_key = entity_def.parent,
                    .child_name = child_name,
                    .inherit_rotation = getFieldOrDefault(entity_def, "inherit_rotation", false),
                    .inherit_scale = getFieldOrDefault(entity_def, "inherit_scale", false),
                });
            }
        }

        /// Load an entity that references a prefab (comptime lookup).
        /// Uses uniform component handling with proper merging - prefab components
        /// are merged with scene overrides, allowing partial overrides of any field.
        fn loadPrefabEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: *loader_types.ReferenceContext,
        ) !EntityInstance {
            const prefab_name = entity_def.prefab;

            // Verify prefab exists at compile time
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found: " ++ prefab_name);
                }
            }

            const game = ctx.game();

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position (scene overrides prefab)
            const pos = Ops.getPrefabPosition(prefab_name, entity_def);

            // Add Position component
            game.getRegistry().addComponent(entity, Position{ .x = pos.x, .y = pos.y });

            // Set current entity for self-references
            ref_ctx.current_entity = entity;

            // Add components from prefab, merging with scene overrides where present
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                const scene_components = if (@hasField(@TypeOf(entity_def), "components"))
                    entity_def.components
                else
                    .{};

                try Ops.addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos.x, pos.y, no_parent, ready_queue, ref_ctx);
            }

            // Add scene-only components (components in scene that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try Ops.addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos.x, pos.y, no_parent, ready_queue, ref_ctx);
                } else {
                    // No prefab components, add all scene components
                    try Ops.addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"}, no_parent, ready_queue, ref_ctx);
                }
            }

            // Create gizmo entities (debug builds only)
            // First check scene-level gizmos (can override prefab gizmos)
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try Ops.createGizmoEntities(game, scene, entity, entity_def.gizmos, pos.x, pos.y, ready_queue);
            } else if (comptime Prefabs.hasGizmos(prefab_name)) {
                // Fall back to prefab gizmos if no scene-level override
                try Ops.createGizmoEntities(game, scene, entity, Prefabs.getGizmos(prefab_name), pos.x, pos.y, ready_queue);
            }

            // Queue parent-child relationship if .parent field is present (RFC #243)
            try queueParentIfPresent(entity_def, entity, ref_ctx);

            return .{
                .entity = entity,
                .visual_type = comptime Ops.getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load an inline entity with components.
        /// Handles all component types uniformly - visual components (Sprite, Shape, Text)
        /// are registered with the render pipeline via their onAdd callbacks.
        fn loadComponentEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: *loader_types.ReferenceContext,
        ) !EntityInstance {
            const game = ctx.game();

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position
            const pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };

            // Add Position component
            game.getRegistry().addComponent(entity, Position{ .x = pos.x, .y = pos.y });

            // Set current entity for self-references (Issue #242)
            ref_ctx.current_entity = entity;

            // Add all components (Sprite/Shape/Text handled via fromZonData, others generically)
            // Position is excluded since we already added it above
            try Ops.addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"}, no_parent, ready_queue, ref_ctx);

            // Create gizmo entities if present (debug builds only)
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try Ops.createGizmoEntities(game, scene, entity, entity_def.gizmos, pos.x, pos.y, ready_queue);
            }

            // Queue parent-child relationship if .parent field is present (RFC #243)
            try queueParentIfPresent(entity_def, entity, ref_ctx);

            return .{
                .entity = entity,
                .visual_type = comptime Ops.getVisualTypeFromComponents(entity_def.components),
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }
    };
}
