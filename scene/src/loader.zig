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
//         // Shape entities (position inside .shape block):
//         .{ .shape = .{ .type = .circle, .x = 100, .y = 100, .radius = 50, .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } },
//         .{ .shape = .{ .type = .rectangle, .x = 200, .y = 200, .width = 100, .height = 50 } },
//         // Sprite entities with position in .components:
//         .{ .components = .{ .Position = .{ .x = 300, .y = 150 }, .Sprite = .{ .name = "gem.png" }, .Health = .{ .current = 50 } } },
//         // Data-only entities (no visual):
//         .{ .components = .{ .Position = .{ .x = 100, .y = 100 }, .Health = .{ .current = 100 } } },
//     },
// }
//
// Pivot values: .center, .top_left, .top_center, .top_right, .center_left,
//               .center_right, .bottom_left, .bottom_center, .bottom_right, .custom
// For .custom pivot, also specify .pivot_x and .pivot_y (0.0-1.0)

const std = @import("std");
const ecs = @import("ecs");
const zon = @import("../../core/src/zon_coercion.zig");
const prefab_mod = @import("prefab.zig");
const core_mod = @import("core.zig");
const component_mod = @import("component.zig");
const script_mod = @import("script.zig");
const game_mod = @import("../../engine/game.zig");

pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

pub const PrefabRegistry = prefab_mod.PrefabRegistry;
pub const Scene = core_mod.Scene;
pub const SceneContext = core_mod.SceneContext;
pub const EntityInstance = core_mod.EntityInstance;
pub const VisualType = core_mod.VisualType;
pub const Game = game_mod.Game;


/// Scene-level camera configuration
pub const SceneCameraConfig = struct {
    x: ?f32 = null,
    y: ?f32 = null,
    zoom: f32 = 1.0,
};

/// Named camera slot for multi-camera scenes
pub const CameraSlot = enum(u2) {
    main = 0, // Primary camera (camera 0)
    player2 = 1, // Second player camera (camera 1)
    minimap = 2, // Minimap/overview camera (camera 2)
    camera3 = 3, // Fourth camera (camera 3)
};

/// Get a field from comptime data or return a default value if not present
fn getFieldOrDefault(comptime data: anytype, comptime field_name: []const u8, comptime default: anytype) @TypeOf(default) {
    if (@hasField(@TypeOf(data), field_name)) {
        return @field(data, field_name);
    } else {
        return default;
    }
}

/// Simple position struct for loader internal use
const Pos = struct { x: f32, y: f32 };

/// Get position from entity definition's .components.Position
/// Returns null if no Position component is defined
fn getPositionFromComponents(comptime entity_def: anytype) ?Pos {
    if (@hasField(@TypeOf(entity_def), "components")) {
        if (@hasField(@TypeOf(entity_def.components), "Position")) {
            const pos = entity_def.components.Position;
            return .{
                .x = getFieldOrDefault(pos, "x", @as(f32, 0)),
                .y = getFieldOrDefault(pos, "y", @as(f32, 0)),
            };
        }
    }
    return null;
}

/// Apply camera configuration from comptime config data to a camera
fn applyCameraConfig(comptime config: anytype, camera: anytype) void {
    // Extract optional x and y values
    const x: ?f32 = if (@hasField(@TypeOf(config), "x") and @TypeOf(config.x) != @TypeOf(null))
        config.x
    else
        null;
    const y: ?f32 = if (@hasField(@TypeOf(config), "y") and @TypeOf(config.y) != @TypeOf(null))
        config.y
    else
        null;

    // Apply position if either coordinate is specified
    if (x != null or y != null) {
        camera.setPosition(x orelse 0, y orelse 0);
    }

    // Apply zoom if specified
    if (@hasField(@TypeOf(config), "zoom")) {
        camera.setZoom(config.zoom);
    }
}

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
        ) !EntityInstance {
            const instance = try createChildEntity(game, scene, entity_def, parent_x, parent_y);
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
        ) ![]Entity {
            const entity_count = @typeInfo(@TypeOf(entity_defs)).@"struct".fields.len;

            // Allocate slice for entity references
            const entities = try game.allocator.alloc(Entity, entity_count);

            // Create each child entity
            inline for (0..entity_count) |i| {
                const entity_def = entity_defs[i];
                const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y);
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
        ) !EntityInstance {
            // Check if this is a prefab reference
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try createChildPrefabEntity(game, scene, entity_def, parent_x, parent_y);
            }

            // Inline entity with components - visual type is determined by which components are present
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try createChildComponentEntity(game, scene, entity_def, parent_x, parent_y);
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

                try addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos_x, pos_y);
            }

            // Add entity_def-only components (components in entity_def that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos_x, pos_y);
                } else {
                    try addComponentsExcluding(game, scene, entity, entity_def.components, pos_x, pos_y, .{"Position"});
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
        ) !EntityInstance {
            const entity = game.createEntity();

            // Get position from .components.Position, relative to parent
            const local_pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };
            const child_x = parent_x + local_pos.x;
            const child_y = parent_y + local_pos.y;
            game.getRegistry().add(entity, Position{ .x = child_x, .y = child_y });

            // Add all components (Sprite/Shape/Text handled via fromZonData, others generically)
            // Position is excluded since we already added it above
            try addComponentsExcluding(game, scene, entity, entity_def.components, child_x, child_y, .{"Position"});

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
        fn addComponentWithNestedEntities(
            game: *Game,
            scene: ?*Scene,
            parent_entity: Entity,
            comptime comp_name: []const u8,
            comptime comp_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            // Generic component handling
            const ComponentType = Components.getType(comp_name);
            const comp_fields = @typeInfo(ComponentType).@"struct".fields;
            var component: ComponentType = undefined;

            // Process each field in the component type
            inline for (comp_fields) |comp_field| {
                const field_name = comp_field.name;

                if (@hasField(@TypeOf(comp_data), field_name)) {
                    // Data provides this field
                    if (comptime zon.isEntitySlice(comp_field.type)) {
                        // This field is []const Entity - create child entities from the tuple
                        const entity_defs = @field(comp_data, field_name);
                        @field(component, field_name) = try createChildEntities(game, scene, entity_defs, parent_x, parent_y);
                    } else if (comptime zon.isEntity(comp_field.type)) {
                        // This field is a single Entity - create child entity from definition
                        const entity_def = @field(comp_data, field_name);
                        const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y);
                        @field(component, field_name) = instance.entity;
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
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y);
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
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y);
            }
        }

        /// Load a scene from comptime .zon data
        pub fn load(
            comptime scene_data: anytype,
            ctx: SceneContext,
        ) !Scene {
            // Register component lifecycle callbacks (onAdd, onSet, onRemove) for all components.
            // This must be called for each new registry/world (e.g., after scene changes).
            Components.registerCallbacks(ctx.game().getRegistry());

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
                const game = ctx.game();

                inline for (@typeInfo(@TypeOf(cameras)).@"struct".fields) |field| {
                    const cam = @field(cameras, field.name);
                    const slot = comptime std.meta.stringToEnum(CameraSlot, field.name) orelse
                        @compileError("Unknown camera name: '" ++ field.name ++ "'. Valid names: main, player2, minimap, camera3");
                    applyCameraConfig(cam, game.getCameraAt(@intFromEnum(slot)));
                }
            } else if (@hasField(@TypeOf(scene_data), "camera")) {
                // Single camera (primary camera)
                applyCameraConfig(scene_data.camera, ctx.game().getCamera());
            }

            // Process each entity definition
            inline for (scene_data.entities) |entity_def| {
                const instance = try loadEntity(entity_def, ctx, &scene);
                try scene.addEntity(instance);
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

            // Add all components from prefab (excluding Position which we already handled)
            // Visual components (Sprite, Shape, Text) are registered with pipeline via onAdd callbacks
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsExcluding(game, scene, entity, Prefabs.getComponents(prefab_name), x, y, .{"Position"});
            }

            // Add entity to scene
            try scene.addEntity(.{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            });

            return entity;
        }

        /// Load a single entity from its definition.
        /// Visual components (Sprite, Shape, Text) are handled uniformly through
        /// addComponentsExcluding, with their onAdd callbacks handling pipeline registration.
        fn loadEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
        ) !EntityInstance {
            // Check if this references a prefab
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try loadPrefabEntity(entity_def, ctx, scene);
            }

            // Inline entity with components
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try loadComponentEntity(entity_def, ctx, scene);
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

                try addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos.x, pos.y);
            }

            // Add scene-only components (components in scene that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos.x, pos.y);
                } else {
                    // No prefab components, add all scene components
                    try addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"});
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
                    try addComponentWithNestedEntities(game, scene, entity, field_name, merged_data, parent_x, parent_y);
                } else {
                    // Use prefab data as-is
                    try addComponentWithNestedEntities(game, scene, entity, field_name, prefab_data, parent_x, parent_y);
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
        ) !void {
            const scene_fields = comptime std.meta.fieldNames(@TypeOf(scene_components));

            inline for (scene_fields) |field_name| {
                // Skip Position - already handled
                if (comptime std.mem.eql(u8, field_name, "Position")) continue;

                // Skip components that exist in prefab (already handled by addMergedPrefabComponents)
                if (@hasField(@TypeOf(prefab_components), field_name)) continue;

                const scene_data = @field(scene_components, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, scene_data, parent_x, parent_y);
            }
        }

        /// Load an inline entity with components.
        /// Handles all component types uniformly - visual components (Sprite, Shape, Text)
        /// are registered with the render pipeline via their onAdd callbacks.
        fn loadComponentEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
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
            try addComponentsExcluding(game, scene, entity, entity_def.components, pos.x, pos.y, .{"Position"});

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
