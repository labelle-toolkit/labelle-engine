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
const builtin = @import("builtin");
const ecs = @import("ecs");
const zon = @import("../../core/src/zon_coercion.zig");
const prefab_mod = @import("prefab.zig");
const core_mod = @import("core.zig");
const component_mod = @import("component.zig");
const script_mod = @import("script.zig");
const game_mod = @import("../../engine/game.zig");
const loader_types = @import("loader/types.zig");
const render = @import("../../render/src/pipeline.zig");

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

    return struct {
        const Self = @This();

        /// Create child entities from a tuple of entity definitions.
        /// Supports full entity definitions including shapes, sprites, and prefab references.
        ///
        /// When scene is provided:
        /// - Child entities are added to scene.entities for lifecycle management
        /// - Allocated entity slices are tracked in scene.allocated_entity_slices for cleanup
        ///
        /// When scene is null:
        /// - Caller is responsible for entity cleanup (destroy via registry)
        /// - Allocated slice ownership transfers to caller (must free via game.allocator)
        /// Create a child entity and track it in the scene for cleanup.
        fn createAndTrackChildEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const instance = try createChildEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            if (scene) |s| {
                try s.addEntity(instance);
            }
            return instance;
        }

        fn createChildEntities(
            game: *Game,
            scene: ?*Scene,
            comptime entity_defs: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) ![]Entity {
            const entity_count = @typeInfo(@TypeOf(entity_defs)).@"struct".fields.len;

            // Allocate slice for entity references
            const entities = try game.allocator.alloc(Entity, entity_count);

            // Create each child entity
            inline for (0..entity_count) |i| {
                const entity_def = entity_defs[i];
                const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
                entities[i] = instance.entity;
            }

            // Track the allocated slice for cleanup on scene deinit
            if (scene) |s| {
                try s.trackAllocatedSlice(entities);
            }

            return entities;
        }

        /// Create a single child entity with support for prefabs or inline components.
        /// Positions are relative to parent.
        /// Visual components (Sprite, Shape, Text) are handled uniformly through
        /// addComponentsExcluding, with their onAdd callbacks handling pipeline registration.
        fn createChildEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            // Check if this is a prefab reference
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try createChildPrefabEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            }

            // Inline entity with components - visual type is determined by which components are present
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try createChildComponentEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            }

            @compileError("Child entity must have .prefab or .components field");
        }

        /// Create a child entity that references a prefab.
        /// Uses uniform component handling - visual components are registered via onAdd callbacks.
        fn createChildPrefabEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const prefab_name = entity_def.prefab;

            // Verify prefab exists at compile time
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found in nested entity: " ++ prefab_name);
                }
            }

            const entity = game.createEntity();

            // Get position from .components.Position (scene overrides prefab), relative to parent
            const local_pos = getPrefabPosition(prefab_name, entity_def);
            const pos_x = parent_x + local_pos.x;
            const pos_y = parent_y + local_pos.y;

            game.getRegistry().add(entity, Position{ .x = pos_x, .y = pos_y });

            // Add components from prefab, merging with entity_def overrides where present
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                const scene_components = if (@hasField(@TypeOf(entity_def), "components"))
                    entity_def.components
                else
                    .{};

                try addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos_x, pos_y, parent_ctx, ready_queue);
            }

            // Add entity_def-only components (components in entity_def that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos_x, pos_y, parent_ctx, ready_queue);
                } else {
                    try addComponentsExcluding(game, scene, entity, entity_def.components, pos_x, pos_y, .{"Position"}, parent_ctx, ready_queue);
                }
            }

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Determine visual type from component definitions at compile time
        fn getVisualTypeFromComponents(comptime components: anytype) VisualType {
            // Priority: sprite > shape > text > none
            if (@hasField(@TypeOf(components), "Sprite")) return .sprite;
            if (@hasField(@TypeOf(components), "Shape")) return .shape;
            if (@hasField(@TypeOf(components), "Text")) return .text;
            return .none;
        }

        /// Create a child entity from inline component definitions.
        /// Handles all component types uniformly - visual components (Sprite, Shape, Text)
        /// are registered with the render pipeline via their onAdd callbacks.
        fn createChildComponentEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const entity = game.createEntity();

            // Get position from .components.Position, relative to parent
            const local_pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };
            const child_x = parent_x + local_pos.x;
            const child_y = parent_y + local_pos.y;
            game.getRegistry().add(entity, Position{ .x = child_x, .y = child_y });

            // Add all components (Sprite/Shape/Text handled via fromZonData, others generically)
            // Position is excluded since we already added it above
            try addComponentsExcluding(game, scene, entity, entity_def.components, child_x, child_y, .{"Position"}, parent_ctx, ready_queue);

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromComponents(entity_def.components),
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Add a component, creating child entities for any []const Entity fields.
        /// If scene is provided, child entities are tracked for cleanup.
        /// Supports parent reference convention: if parent_ctx is provided and this component
        /// has a field matching the parent component name (lowercased), it will be set to the parent entity.
        fn addComponentWithNestedEntities(
            game: *Game,
            scene: ?*Scene,
            parent_entity: Entity,
            comptime comp_name: []const u8,
            comptime comp_data: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            // Generic component handling
            const ComponentType = Components.getType(comp_name);
            const comp_fields = @typeInfo(ComponentType).@"struct".fields;
            var component: ComponentType = undefined;

            // Create a new parent context for child entities of this component
            const child_parent_ctx = ParentContext{
                .entity = parent_entity,
                .component_name = comp_name,
            };

            // Process each field in the component type
            inline for (comp_fields) |comp_field| {
                const field_name = comp_field.name;

                // Handle Entity fields specially for parent reference auto-population (RFC #169)
                if (comptime comp_field.type == Entity) {
                    // Check at runtime if this is a parent reference field
                    // Convention: field name matches parent component name (lowercased)
                    const is_parent_ref = is_parent_ref: {
                        const ctx = parent_ctx orelse break :is_parent_ref false;
                        if (field_name.len != ctx.component_name.len) break :is_parent_ref false;
                        inline for (field_name, 0..) |f, i| {
                            const p = ctx.component_name[i];
                            const lower_p = if (p >= 'A' and p <= 'Z') p + 32 else p;
                            if (f != lower_p) break :is_parent_ref false;
                        }
                        break :is_parent_ref true;
                    };

                    if (is_parent_ref) {
                        // Auto-populate parent reference field
                        @field(component, field_name) = parent_ctx.?.entity;
                    } else if (@hasField(@TypeOf(comp_data), field_name)) {
                        // Single Entity field - create child entity from definition
                        const entity_def = @field(comp_data, field_name);
                        const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y, child_parent_ctx, ready_queue);
                        @field(component, field_name) = instance.entity;
                    } else if (comp_field.default_value_ptr) |ptr| {
                        const default_ptr: *const comp_field.type = @ptrCast(@alignCast(ptr));
                        @field(component, field_name) = default_ptr.*;
                    } else {
                        @compileError("Missing required field '" ++ field_name ++ "' for component '" ++ comp_name ++ "'");
                    }
                } else if (@hasField(@TypeOf(comp_data), field_name)) {
                    // Data provides this field
                    if (comptime zon.isEntitySlice(comp_field.type)) {
                        // This field is []const Entity - create child entities from the tuple
                        const entity_defs = @field(comp_data, field_name);
                        @field(component, field_name) = try createChildEntities(game, scene, entity_defs, parent_x, parent_y, child_parent_ctx, ready_queue);
                    } else {
                        // Regular field - coerce to handle nested structs and tuples
                        const data_value = @field(comp_data, field_name);
                        @field(component, field_name) = zon.coerceValue(comp_field.type, data_value);
                    }
                } else if (comp_field.default_value_ptr) |ptr| {
                    // Field not provided but has a default value
                    const default_ptr: *const comp_field.type = @ptrCast(@alignCast(ptr));
                    @field(component, field_name) = default_ptr.*;
                } else {
                    // Required field not provided - compile-time error
                    @compileError("Missing required field '" ++ field_name ++ "' for component '" ++ comp_name ++ "'");
                }
            }

            game.getRegistry().add(parent_entity, component);

            // Queue onReady callback if component defines one
            if (@hasDecl(ComponentType, "onReady")) {
                try ready_queue.append(game.allocator, .{
                    .entity = parent_entity,
                    .callback = ComponentType.onReady,
                });
            }
        }

        /// Add all components, handling nested entity definitions where present.
        /// If scene is provided, child entities are tracked for cleanup.
        fn addComponentsWithNestedEntities(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y, parent_ctx, ready_queue);
            }
        }

        /// Add all components except those in the excluded_names tuple.
        /// Used when certain components (like Position, Sprite, Shape) are handled separately.
        fn addComponentsExcluding(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
            comptime excluded_names: anytype,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));

            data_field_loop: inline for (data_fields) |field_name| {
                // Check if this field should be excluded
                inline for (excluded_names) |excluded| {
                    if (comptime std.mem.eql(u8, field_name, excluded)) {
                        continue :data_field_loop;
                    }
                }
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y, parent_ctx, ready_queue);
            }
        }

        /// Load a scene from comptime .zon data
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

            var scene = Scene.init(scene_data.name, script_fns, ctx);
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

            // Process each entity definition
            inline for (scene_data.entities) |entity_def| {
                const instance = try loadEntity(entity_def, ctx, &scene, &ready_queue);
                try scene.addEntity(instance);
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
            game.getRegistry().add(entity, Position{ .x = x, .y = y });

            // Queue for onReady callbacks
            var ready_queue: std.ArrayListUnmanaged(ReadyCallbackEntry) = .{};
            defer ready_queue.deinit(game.allocator);

            // Add all components from prefab (excluding Position which we already handled)
            // Visual components (Sprite, Shape, Text) are registered with pipeline via onAdd callbacks
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsExcluding(game, scene, entity, Prefabs.getComponents(prefab_name), x, y, .{"Position"}, no_parent, &ready_queue);
            }

            // Add entity to scene
            try scene.addEntity(.{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromPrefab(prefab_name),
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
        ) !EntityInstance {
            // Check if this references a prefab
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try loadPrefabEntity(entity_def, ctx, scene, ready_queue);
            }

            // Inline entity with components
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try loadComponentEntity(entity_def, ctx, scene, ready_queue);
            }

            @compileError("Entity must have .prefab or .components field");
        }

        /// Get position for a prefab entity: scene .components.Position overrides prefab .components.Position
        fn getPrefabPosition(comptime prefab_name: []const u8, comptime entity_def: anytype) Pos {
            // Scene-level Position takes precedence
            if (getPositionFromComponents(entity_def)) |pos| {
                return pos;
            }
            // Fall back to prefab's Position
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                if (@hasField(@TypeOf(prefab_components), "Position")) {
                    const p = prefab_components.Position;
                    return Pos{
                        .x = getFieldOrDefault(p, "x", @as(f32, 0)),
                        .y = getFieldOrDefault(p, "y", @as(f32, 0)),
                    };
                }
            }
            return Pos{ .x = 0, .y = 0 };
        }

        /// Determine visual type from prefab components at compile time
        fn getVisualTypeFromPrefab(comptime prefab_name: []const u8) VisualType {
            if (!Prefabs.hasComponents(prefab_name)) return .none;
            const components = Prefabs.getComponents(prefab_name);
            return getVisualTypeFromComponents(components);
        }

        /// Load an entity that references a prefab (comptime lookup).
        /// Uses uniform component handling with proper merging - prefab components
        /// are merged with scene overrides, allowing partial overrides of any field.
        fn loadPrefabEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
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
            const pos = getPrefabPosition(prefab_name, entity_def);

            // Add Position component
            game.getRegistry().add(entity, Position{ .x = pos.x, .y = pos.y });

            // Add components from prefab, merging with scene overrides where present
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                const scene_components = if (@hasField(@TypeOf(entity_def), "components"))
                    entity_def.components
                else
                    .{};

                try addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos.x, pos.y, no_parent, ready_queue);
            }

            // Add scene-only components (components in scene that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos.x, pos.y, no_parent, ready_queue);
                } else {
                    // No prefab components, add all scene components
                    try addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"}, no_parent, ready_queue);
                }
            }

            // Create gizmo entities (debug builds only)
            // First check scene-level gizmos (can override prefab gizmos)
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try createGizmoEntities(game, scene, entity, entity_def.gizmos, pos.x, pos.y, ready_queue);
            } else if (comptime Prefabs.hasGizmos(prefab_name)) {
                // Fall back to prefab gizmos if no scene-level override
                try createGizmoEntities(game, scene, entity, Prefabs.getGizmos(prefab_name), pos.x, pos.y, ready_queue);
            }

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Add prefab components with scene overrides merged in.
        /// For each component in prefab_components:
        ///   - If scene_components has the same component, merge the two
        ///   - Otherwise, use prefab component as-is
        fn addMergedPrefabComponents(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime prefab_components: anytype,
            comptime scene_components: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            const prefab_fields = comptime std.meta.fieldNames(@TypeOf(prefab_components));

            inline for (prefab_fields) |field_name| {
                // Skip Position - already handled
                if (comptime std.mem.eql(u8, field_name, "Position")) continue;

                const prefab_data = @field(prefab_components, field_name);

                if (@hasField(@TypeOf(scene_components), field_name)) {
                    // Merge prefab + scene override
                    const scene_data = @field(scene_components, field_name);
                    const merged_data = zon.mergeStructs(prefab_data, scene_data);
                    try addComponentWithNestedEntities(game, scene, entity, field_name, merged_data, parent_x, parent_y, parent_ctx, ready_queue);
                } else {
                    // Use prefab data as-is
                    try addComponentWithNestedEntities(game, scene, entity, field_name, prefab_data, parent_x, parent_y, parent_ctx, ready_queue);
                }
            }
        }

        /// Add components that exist only in scene (not in prefab).
        fn addSceneOnlyComponents(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime prefab_components: anytype,
            comptime scene_components: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            const scene_fields = comptime std.meta.fieldNames(@TypeOf(scene_components));

            inline for (scene_fields) |field_name| {
                // Skip Position - already handled
                if (comptime std.mem.eql(u8, field_name, "Position")) continue;

                // Skip components that exist in prefab (already handled by addMergedPrefabComponents)
                if (@hasField(@TypeOf(prefab_components), field_name)) continue;

                const scene_data = @field(scene_components, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, scene_data, parent_x, parent_y, parent_ctx, ready_queue);
            }
        }

        /// Create gizmo entities for debug visualization.
        /// Gizmos are only created in debug builds and are attached to a parent entity.
        /// Each gizmo entity gets a Gizmo marker component for visibility toggling.
        fn createGizmoEntities(
            game: *Game,
            scene: ?*Scene,
            parent_entity: Entity,
            comptime gizmos_data: anytype,
            parent_x: f32,
            parent_y: f32,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            // Only create gizmos in debug builds
            if (builtin.mode != .Debug) return;

            const gizmo_fields = @typeInfo(@TypeOf(gizmos_data)).@"struct".fields;

            // Process each gizmo definition (these are component definitions like Shape, Text, Sprite)
            inline for (gizmo_fields) |field| {
                const field_name = field.name;
                const gizmo_data = @field(gizmos_data, field_name);

                // Create a new entity for this gizmo
                const gizmo_entity = game.createEntity();

                // Get offset from the gizmo data's Position if present, otherwise use 0,0
                const offset_x: f32 = if (@hasField(@TypeOf(gizmo_data), "x")) gizmo_data.x else 0;
                const offset_y: f32 = if (@hasField(@TypeOf(gizmo_data), "y")) gizmo_data.y else 0;

                // Add Position at parent position + offset
                game.getRegistry().add(gizmo_entity, Position{ .x = parent_x + offset_x, .y = parent_y + offset_y });

                // Add Gizmo marker component with parent reference
                game.getRegistry().add(gizmo_entity, render.Gizmo{
                    .parent_entity = parent_entity,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                });

                // Handle BoundingBox gizmos specially - they create a Shape from parent's visual bounds
                if (comptime std.mem.eql(u8, field_name, "BoundingBox")) {
                    // Create BoundingBox component from gizmo data
                    const bbox = render.BoundingBox{
                        .color = if (@hasField(@TypeOf(gizmo_data), "color")) zon.coerceValue(render.Color, gizmo_data.color) else .{ .r = 0, .g = 255, .b = 0, .a = 200 },
                        .padding = if (@hasField(@TypeOf(gizmo_data), "padding")) gizmo_data.padding else 0,
                        .thickness = if (@hasField(@TypeOf(gizmo_data), "thickness")) gizmo_data.thickness else 1,
                        .visible = if (@hasField(@TypeOf(gizmo_data), "visible")) gizmo_data.visible else true,
                        .z_index = if (@hasField(@TypeOf(gizmo_data), "z_index")) gizmo_data.z_index else 255,
                        .layer = if (@hasField(@TypeOf(gizmo_data), "layer")) gizmo_data.layer else .ui,
                    };

                    // Store BoundingBox component for reference
                    game.getRegistry().add(gizmo_entity, bbox);

                    // Get parent entity's visual bounds and create Shape
                    if (game.getEntityVisualBounds(parent_entity)) |bounds| {
                        const shape = bbox.toShape(bounds.width, bounds.height);
                        game.getRegistry().add(gizmo_entity, shape);
                    } else {
                        // Fallback to a small default shape if bounds unavailable
                        const shape = bbox.toShape(32, 32);
                        game.getRegistry().add(gizmo_entity, shape);
                        std.log.warn("BoundingBox gizmo: could not get parent visual bounds, using default 32x32", .{});
                    }
                } else {
                    // Add the visual component (Shape, Text, Sprite, Icon)
                    try addComponentWithNestedEntities(game, scene, gizmo_entity, field_name, gizmo_data, parent_x + offset_x, parent_y + offset_y, no_parent, ready_queue);
                }

                // Track in scene for cleanup
                if (scene) |s| {
                    try s.addEntity(.{
                        .entity = gizmo_entity,
                        .visual_type = comptime getVisualTypeFromGizmo(field_name),
                        .prefab_name = null,
                        .onUpdate = null,
                        .onDestroy = null,
                    });
                }
            }
        }

        /// Determine visual type from gizmo component name at compile time
        fn getVisualTypeFromGizmo(comptime comp_name: []const u8) VisualType {
            if (comptime std.mem.eql(u8, comp_name, "Sprite")) return .sprite;
            if (comptime std.mem.eql(u8, comp_name, "Shape")) return .shape;
            if (comptime std.mem.eql(u8, comp_name, "Text")) return .text;
            if (comptime std.mem.eql(u8, comp_name, "Icon")) return .sprite;
            if (comptime std.mem.eql(u8, comp_name, "BoundingBox")) return .shape;
            return .none;
        }

        /// Load an inline entity with components.
        /// Handles all component types uniformly - visual components (Sprite, Shape, Text)
        /// are registered with the render pipeline via their onAdd callbacks.
        fn loadComponentEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const game = ctx.game();

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position
            const pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };

            // Add Position component
            game.getRegistry().add(entity, Position{ .x = pos.x, .y = pos.y });

            // Add all components (Sprite/Shape/Text handled via fromZonData, others generically)
            // Position is excluded since we already added it above
            try addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"}, no_parent, ready_queue);

            // Create gizmo entities if present (debug builds only)
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try createGizmoEntities(game, scene, entity, entity_def.gizmos, pos.x, pos.y, ready_queue);
            }

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromComponents(entity_def.components),
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }
    };
}
