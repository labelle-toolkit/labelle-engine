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
const zon = @import("zon_coercion.zig");
const prefab_mod = @import("prefab.zig");
const scene_mod = @import("scene.zig");
const component_mod = @import("component.zig");
const script_mod = @import("script.zig");
const render_pipeline_mod = @import("render_pipeline.zig");
const game_mod = @import("game.zig");

pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

pub const SpriteConfig = prefab_mod.SpriteConfig;
pub const PrefabRegistry = prefab_mod.PrefabRegistry;
pub const ZIndex = prefab_mod.ZIndex;
pub const Scene = scene_mod.Scene;
pub const SceneContext = scene_mod.SceneContext;
pub const EntityInstance = scene_mod.EntityInstance;
pub const VisualType = scene_mod.VisualType;
pub const Game = game_mod.Game;

// Render pipeline types
pub const Position = render_pipeline_mod.Position;
pub const Sprite = render_pipeline_mod.Sprite;
pub const Shape = render_pipeline_mod.Shape;
pub const Color = render_pipeline_mod.Color;
pub const ShapeVisual = render_pipeline_mod.ShapeVisual;

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

/// Check if entity definition has a Sprite component in its .components block
fn hasSpriteInComponents(comptime entity_def: anytype) bool {
    if (@hasField(@TypeOf(entity_def), "components")) {
        return @hasField(@TypeOf(entity_def.components), "Sprite");
    }
    return false;
}

/// Check if entity definition has a Shape component in its .components block
fn hasShapeInComponents(comptime entity_def: anytype) bool {
    if (@hasField(@TypeOf(entity_def), "components")) {
        return @hasField(@TypeOf(entity_def.components), "Shape");
    }
    return false;
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

/// Get sprite name from sprite data (.name or .sprite_name field)
fn getSpriteName(comptime sprite_data: anytype) []const u8 {
    if (@hasField(@TypeOf(sprite_data), "name")) {
        return sprite_data.name;
    } else if (@hasField(@TypeOf(sprite_data), "sprite_name")) {
        return sprite_data.sprite_name;
    } else {
        return "";
    }
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
                const instance = try createChildEntity(game, scene, entity_def, parent_x, parent_y);

                // Track child entity in scene for cleanup
                if (scene) |s| {
                    try s.addEntity(instance);
                }

                entities[i] = instance.entity;
            }

            // Track the allocated slice for cleanup on scene deinit
            if (scene) |s| {
                try s.trackAllocatedSlice(entities);
            }

            return entities;
        }

        /// Create a single child entity with support for shapes, sprites, prefabs, or data-only.
        /// Positions are relative to parent.
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

            // Check if this has Shape in .components (new format)
            if (comptime hasShapeInComponents(entity_def)) {
                return try createChildShapeComponentEntity(game, scene, entity_def, parent_x, parent_y);
            }

            // Check if this has Sprite in .components
            if (comptime hasSpriteInComponents(entity_def)) {
                return try createChildSpriteEntity(game, scene, entity_def, parent_x, parent_y);
            }

            // Data-only entity (no visual)
            return try createChildDataEntity(game, scene, entity_def, parent_x, parent_y);
        }

        /// Create a child entity that references a prefab
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

            // Get sprite config from prefab with entity_def overrides (excludes position)
            const sprite_config = Prefabs.getSprite(prefab_name, entity_def);

            // Get position from .components.Position (scene overrides prefab), relative to parent
            const local_pos = getPrefabPosition(prefab_name, entity_def);
            const pos_x = parent_x + local_pos.x;
            const pos_y = parent_y + local_pos.y;

            game.addPosition(entity, Position{ .x = pos_x, .y = pos_y });

            try game.addSprite(entity, Sprite{
                .sprite_name = sprite_config.name,
                .scale = sprite_config.scale,
                .rotation = sprite_config.rotation,
                .flip_x = sprite_config.flip_x,
                .flip_y = sprite_config.flip_y,
                .z_index = sprite_config.z_index,
                .pivot = sprite_config.pivot,
                .pivot_x = sprite_config.pivot_x,
                .pivot_y = sprite_config.pivot_y,
            });

            // Add components from prefab definition (excluding Sprite and Position which are already added)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsExcludingSprite(game, scene, entity, Prefabs.getComponents(prefab_name), pos_x, pos_y);
            }

            // Add/override components from entity definition (excluding Sprite and Position)
            if (@hasField(@TypeOf(entity_def), "components")) {
                try addComponentsExcludingSprite(game, scene, entity, entity_def.components, pos_x, pos_y);
            }

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Create a child shape entity (Shape in .components) with relative positioning
        fn createChildShapeComponentEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !EntityInstance {
            const shape_data = entity_def.components.Shape;
            const entity = game.createEntity();

            // Get position from .components.Position, relative to parent
            const local_pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };
            const pos_x = parent_x + local_pos.x;
            const pos_y = parent_y + local_pos.y;

            game.addPosition(entity, Position{ .x = pos_x, .y = pos_y });

            // Build shape based on type
            const shape_type = shape_data.type;
            var shape: Shape = switch (shape_type) {
                .circle => Shape.circle(getFieldOrDefault(shape_data, "radius", @as(f32, 10))),
                .rectangle => Shape.rectangle(
                    getFieldOrDefault(shape_data, "width", @as(f32, 10)),
                    getFieldOrDefault(shape_data, "height", @as(f32, 10)),
                ),
                .line => Shape.line(
                    getFieldOrDefault(shape_data, "end_x", @as(f32, 10)),
                    getFieldOrDefault(shape_data, "end_y", @as(f32, 0)),
                    getFieldOrDefault(shape_data, "thickness", @as(f32, 1)),
                ),
                else => @compileError("Unknown shape type in nested entity definition"),
            };

            // Color
            if (@hasField(@TypeOf(shape_data), "color")) {
                shape.color = .{
                    .r = shape_data.color.r,
                    .g = shape_data.color.g,
                    .b = shape_data.color.b,
                    .a = if (@hasField(@TypeOf(shape_data.color), "a")) shape_data.color.a else 255,
                };
            }

            // z_index
            if (@hasField(@TypeOf(shape_data), "z_index")) {
                shape.z_index = shape_data.z_index;
            }

            try game.addShape(entity, shape);

            // Add other components (excluding Shape and Position which we already handled)
            try addComponentsExcludingShape(game, scene, entity, entity_def.components, pos_x, pos_y);

            return .{
                .entity = entity,
                .visual_type = .shape,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Create a child sprite entity (Sprite in .components) with relative positioning
        fn createChildSpriteEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !EntityInstance {
            const sprite_data = entity_def.components.Sprite;
            const entity = game.createEntity();

            // Get position from .components.Position, relative to parent
            const local_pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };
            const pos_x = parent_x + local_pos.x;
            const pos_y = parent_y + local_pos.y;

            game.addPosition(entity, Position{ .x = pos_x, .y = pos_y });

            try game.addSprite(entity, Sprite{
                .sprite_name = getSpriteName(sprite_data),
                .z_index = getFieldOrDefault(sprite_data, "z_index", ZIndex.characters),
                .scale = getFieldOrDefault(sprite_data, "scale", @as(f32, 1.0)),
                .rotation = getFieldOrDefault(sprite_data, "rotation", @as(f32, 0)),
                .flip_x = getFieldOrDefault(sprite_data, "flip_x", false),
                .flip_y = getFieldOrDefault(sprite_data, "flip_y", false),
                .pivot = getFieldOrDefault(sprite_data, "pivot", render_pipeline_mod.Pivot.center),
                .pivot_x = getFieldOrDefault(sprite_data, "pivot_x", @as(f32, 0.5)),
                .pivot_y = getFieldOrDefault(sprite_data, "pivot_y", @as(f32, 0.5)),
            });

            // Add other components (excluding Sprite and Position)
            try addComponentsExcludingSprite(game, scene, entity, entity_def.components, pos_x, pos_y);

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Create a data-only child entity (no visual)
        fn createChildDataEntity(
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
            game.addPosition(entity, Position{ .x = child_x, .y = child_y });

            // Add components (recursively handles nested entities), excluding Position
            if (@hasField(@TypeOf(entity_def), "components")) {
                try addComponentsExcludingPosition(game, scene, entity, entity_def.components, child_x, child_y);
            }

            return .{
                .entity = entity,
                .visual_type = .none,
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

        /// Add all components except Sprite and Position (for use when Sprite is in .components block
        /// and has already been handled separately via game.addSprite(), and Position via game.addPosition()).
        fn addComponentsExcludingSprite(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                // Skip Sprite and Position - they're handled specially
                if (comptime !std.mem.eql(u8, field_name, "Sprite") and !std.mem.eql(u8, field_name, "Position")) {
                    const field_data = @field(components_data, field_name);
                    try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y);
                }
            }
        }

        /// Add all components except Position (for data-only entities where Position is handled separately).
        fn addComponentsExcludingPosition(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                // Skip Position - it's handled specially via game.addPosition()
                if (comptime !std.mem.eql(u8, field_name, "Position")) {
                    const field_data = @field(components_data, field_name);
                    try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y);
                }
            }
        }

        /// Add all components except Shape and Position (for use when Shape is in .components block
        /// and has already been handled separately via game.addShape(), and Position via game.addPosition()).
        fn addComponentsExcludingShape(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                // Skip Shape and Position - they're handled specially
                if (comptime !std.mem.eql(u8, field_name, "Shape") and !std.mem.eql(u8, field_name, "Position")) {
                    const field_data = @field(components_data, field_name);
                    try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y);
                }
            }
        }

        /// Load a scene from comptime .zon data
        pub fn load(
            comptime scene_data: anytype,
            ctx: SceneContext,
        ) !Scene {
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
                const game = ctx.game;

                inline for (@typeInfo(@TypeOf(cameras)).@"struct".fields) |field| {
                    const cam = @field(cameras, field.name);
                    const slot = comptime std.meta.stringToEnum(CameraSlot, field.name) orelse
                        @compileError("Unknown camera name: '" ++ field.name ++ "'. Valid names: main, player2, minimap, camera3");
                    applyCameraConfig(cam, game.getCameraAt(@intFromEnum(slot)));
                }
            } else if (@hasField(@TypeOf(scene_data), "camera")) {
                // Single camera (primary camera)
                applyCameraConfig(scene_data.camera, ctx.game.getCamera());
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

            const game = ctx.game;

            // Create ECS entity
            const entity = game.createEntity();

            // Get sprite config from prefab (no scene overrides for runtime instantiation)
            const sprite_config = Prefabs.getSprite(prefab_name, .{});

            // Add Position component (sprite_config.x/y are ignored for runtime instantiation)
            game.addPosition(entity, Position{ .x = x, .y = y });

            // Add Sprite component and track for rendering
            try game.addSprite(entity, Sprite{
                .sprite_name = sprite_config.name,
                .scale = sprite_config.scale,
                .rotation = sprite_config.rotation,
                .flip_x = sprite_config.flip_x,
                .flip_y = sprite_config.flip_y,
                .z_index = sprite_config.z_index,
                .pivot = sprite_config.pivot,
                .pivot_x = sprite_config.pivot_x,
                .pivot_y = sprite_config.pivot_y,
            });

            // Add components from prefab definition (excluding Sprite which is already added)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsExcludingSprite(game, scene, entity, Prefabs.getComponents(prefab_name), x, y);
            }

            // Add entity to scene
            try scene.addEntity(.{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            });

            return entity;
        }

        /// Load a single entity from its definition
        fn loadEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
        ) !EntityInstance {
            // Check if this references a prefab
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try loadPrefabEntity(entity_def, ctx, scene);
            }

            // Check if this has Shape in .components (new format)
            if (comptime hasShapeInComponents(entity_def)) {
                return try loadShapeComponentEntity(entity_def, ctx, scene);
            }

            // Check if this has Sprite in .components
            if (comptime hasSpriteInComponents(entity_def)) {
                return try loadSpriteEntity(entity_def, ctx, scene);
            }

            // Check if this has components (data-only entity, no visual)
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try loadDataOnlyEntity(entity_def, ctx, scene);
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

        /// Load an entity that references a prefab (comptime lookup)
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

            const game = ctx.game;

            // Create ECS entity
            const entity = game.createEntity();

            // Get sprite config from prefab with scene overrides (excludes position)
            const sprite_config = Prefabs.getSprite(prefab_name, entity_def);

            // Get position from .components.Position (scene overrides prefab)
            const pos = getPrefabPosition(prefab_name, entity_def);

            // Add Position component
            game.addPosition(entity, Position{
                .x = pos.x,
                .y = pos.y,
            });

            // Add Sprite component and track for rendering
            try game.addSprite(entity, Sprite{
                .sprite_name = sprite_config.name,
                .scale = sprite_config.scale,
                .rotation = sprite_config.rotation,
                .flip_x = sprite_config.flip_x,
                .flip_y = sprite_config.flip_y,
                .z_index = sprite_config.z_index,
                .pivot = sprite_config.pivot,
                .pivot_x = sprite_config.pivot_x,
                .pivot_y = sprite_config.pivot_y,
            });

            // Add components from prefab definition (excluding Sprite and Position which are already added)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsExcludingSprite(game, scene, entity, Prefabs.getComponents(prefab_name), pos.x, pos.y);
            }

            // Add/override components from scene definition (excluding Sprite and Position)
            if (@hasField(@TypeOf(entity_def), "components")) {
                try addComponentsExcludingSprite(game, scene, entity, entity_def.components, pos.x, pos.y);
            }

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load a sprite entity (Sprite defined in .components block)
        fn loadSpriteEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
        ) !EntityInstance {
            const game = ctx.game;
            const sprite_data = entity_def.components.Sprite;

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position
            const pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };

            // Add Position component
            game.addPosition(entity, Position{
                .x = pos.x,
                .y = pos.y,
            });

            // Add Sprite component
            try game.addSprite(entity, Sprite{
                .sprite_name = getSpriteName(sprite_data),
                .z_index = getFieldOrDefault(sprite_data, "z_index", ZIndex.characters),
                .scale = getFieldOrDefault(sprite_data, "scale", @as(f32, 1.0)),
                .rotation = getFieldOrDefault(sprite_data, "rotation", @as(f32, 0)),
                .flip_x = getFieldOrDefault(sprite_data, "flip_x", false),
                .flip_y = getFieldOrDefault(sprite_data, "flip_y", false),
                .pivot = getFieldOrDefault(sprite_data, "pivot", render_pipeline_mod.Pivot.center),
                .pivot_x = getFieldOrDefault(sprite_data, "pivot_x", @as(f32, 0.5)),
                .pivot_y = getFieldOrDefault(sprite_data, "pivot_y", @as(f32, 0.5)),
            });

            // Add other components (excluding Sprite which we already handled)
            try addComponentsExcludingSprite(game, scene, entity, entity_def.components, pos.x, pos.y);

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load a data-only entity (no visual, just components)
        fn loadDataOnlyEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
        ) !EntityInstance {
            const game = ctx.game;

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position
            const pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };

            // Add Position component
            game.addPosition(entity, Position{
                .x = pos.x,
                .y = pos.y,
            });

            // Add components (handles nested entity creation), excluding Position which we already added
            try addComponentsExcludingPosition(game, scene, entity, entity_def.components, pos.x, pos.y);

            return .{
                .entity = entity,
                .visual_type = .none,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load a shape entity (Shape defined in .components block)
        fn loadShapeComponentEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
            scene: *Scene,
        ) !EntityInstance {
            const game = ctx.game;
            const shape_data = entity_def.components.Shape;

            // Create ECS entity
            const entity = game.createEntity();

            // Get position from .components.Position
            const pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };

            // Add Position component
            game.addPosition(entity, Position{
                .x = pos.x,
                .y = pos.y,
            });

            // Build shape based on type
            const shape_type = shape_data.type;
            var shape: Shape = switch (shape_type) {
                .circle => Shape.circle(getFieldOrDefault(shape_data, "radius", @as(f32, 10))),
                .rectangle => Shape.rectangle(
                    getFieldOrDefault(shape_data, "width", @as(f32, 10)),
                    getFieldOrDefault(shape_data, "height", @as(f32, 10)),
                ),
                .line => Shape.line(
                    getFieldOrDefault(shape_data, "end_x", @as(f32, 10)),
                    getFieldOrDefault(shape_data, "end_y", @as(f32, 0)),
                    getFieldOrDefault(shape_data, "thickness", @as(f32, 1)),
                ),
                else => @compileError("Unknown shape type in scene definition"),
            };

            // Color
            if (@hasField(@TypeOf(shape_data), "color")) {
                shape.color = .{
                    .r = shape_data.color.r,
                    .g = shape_data.color.g,
                    .b = shape_data.color.b,
                    .a = if (@hasField(@TypeOf(shape_data.color), "a")) shape_data.color.a else 255,
                };
            }

            // z_index
            if (@hasField(@TypeOf(shape_data), "z_index")) {
                shape.z_index = shape_data.z_index;
            }

            try game.addShape(entity, shape);

            // Add other components (excluding Shape and Position which we already handled)
            try addComponentsExcludingShape(game, scene, entity, entity_def.components, pos.x, pos.y);

            return .{
                .entity = entity,
                .visual_type = .shape,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }
    };
}
