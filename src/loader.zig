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
//         .{ .prefab = "player", .x = 400, .y = 300 },
//         .{ .prefab = "player", .pivot = .bottom_center },  // pivot override
//         .{ .prefab = "background" },
//         .{ .sprite = .{ .name = "coin.png", .x = 100, .y = 50, .pivot = .center } },
//         .{ .sprite = .{ .name = "cloud.png" }, .components = .{ .Gravity = .{ .strength = 9.8 } } },
//         .{ .shape = .{ .type = .circle, .x = 100, .y = 100, .radius = 50, .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } },
//         .{ .shape = .{ .type = .rectangle, .x = 200, .y = 200, .width = 100, .height = 50 } },
//     },
// }
//
// Pivot values: .center, .top_left, .top_center, .top_right, .center_left,
//               .center_right, .bottom_left, .bottom_center, .bottom_right, .custom
// For .custom pivot, also specify .pivot_x and .pivot_y (0.0-1.0)

const std = @import("std");
const ecs = @import("ecs");
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

        /// Add a component that may have nested child entity definitions
        /// If the component data has a `.components` wrapper, creates child entities and stores their IDs
        fn addComponentWithNestedEntities(
            game: *Game,
            parent_entity: Entity,
            comptime comp_name: []const u8,
            comptime comp_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            const ComponentType = Components.getType(comp_name);

            if (@hasField(@TypeOf(comp_data), "components")) {
                // This component has nested entity definitions via .components wrapper
                const nested_data = comp_data.components;
                var component: ComponentType = .{};

                // For each field in nested_data (e.g., "bazzes")
                inline for (@typeInfo(@TypeOf(nested_data)).@"struct".fields) |field| {
                    const field_name = field.name;
                    const entity_defs = @field(nested_data, field_name);

                    // Get tuple size at comptime
                    const entity_count = @typeInfo(@TypeOf(entity_defs)).@"struct".fields.len;

                    // Allocate slice for entity references
                    const entities = try game.allocator.alloc(Entity, entity_count);

                    // Create each child entity
                    inline for (0..entity_count) |i| {
                        const entity_def = entity_defs[i];

                        // Create child entity
                        const child = game.createEntity();

                        // Add position with relative offset
                        const child_x = parent_x + getFieldOrDefault(entity_def, "x", @as(f32, 0));
                        const child_y = parent_y + getFieldOrDefault(entity_def, "y", @as(f32, 0));
                        game.addPosition(child, Position{ .x = child_x, .y = child_y });

                        // Add child's components
                        if (@hasField(@TypeOf(entity_def), "components")) {
                            Components.addComponents(game.getRegistry(), child, entity_def.components);
                        }

                        entities[i] = child;
                    }

                    // Set the field on the component
                    @field(component, field_name) = entities;
                }

                // Add any other direct fields from comp_data (non-.components fields)
                inline for (@typeInfo(@TypeOf(comp_data)).@"struct".fields) |field| {
                    if (!std.mem.eql(u8, field.name, "components")) {
                        if (@hasField(ComponentType, field.name)) {
                            @field(component, field.name) = @field(comp_data, field.name);
                        }
                    }
                }

                game.getRegistry().add(parent_entity, component);
            } else {
                // No nested entities, use normal path
                Components.addComponent(game.getRegistry(), parent_entity, comp_name, comp_data);
            }
        }

        /// Add all components, handling nested entity definitions where present
        fn addComponentsWithNestedEntities(
            game: *Game,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, entity, field_name, field_data, parent_x, parent_y);
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
                const instance = try loadEntity(entity_def, ctx);
                try scene.addEntity(instance);
            }

            return scene;
        }

        /// Instantiate a prefab at runtime with a specific world position
        /// Returns the created entity and adds it to the scene
        /// Usage: const entity = try Loader.instantiatePrefab("player", &scene, ctx, 100, 200);
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

            // Use provided position as world position (sprite_config.x/y are ignored for runtime)
            const world_x = x;
            const world_y = y;

            // Add Position component with world position
            game.addPosition(entity, Position{
                .x = world_x,
                .y = world_y,
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

            // Add components from prefab definition (handles nested entity creation)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsWithNestedEntities(game, entity, Prefabs.getComponents(prefab_name), world_x, world_y);
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
        ) !EntityInstance {
            // Check if this references a prefab
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try loadPrefabEntity(entity_def, ctx);
            }

            // Check if this is a shape entity
            if (@hasField(@TypeOf(entity_def), "shape")) {
                return try loadShapeEntity(entity_def, ctx);
            }

            // Otherwise it's an inline sprite definition
            return try loadInlineEntity(entity_def, ctx);
        }

        /// Load an entity that references a prefab (comptime lookup)
        fn loadPrefabEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
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

            // Get sprite config from prefab with scene overrides
            const sprite_config = Prefabs.getSprite(prefab_name, entity_def);

            // Add Position component
            game.addPosition(entity, Position{
                .x = sprite_config.x,
                .y = sprite_config.y,
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

            // Add components from prefab definition (handles nested entity creation)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                try addComponentsWithNestedEntities(game, entity, Prefabs.getComponents(prefab_name), sprite_config.x, sprite_config.y);
            }

            // Add/override components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                try addComponentsWithNestedEntities(game, entity, entity_def.components, sprite_config.x, sprite_config.y);
            }

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load an inline entity (no prefab)
        fn loadInlineEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
        ) !EntityInstance {
            // Must have sprite field for inline entities
            if (!@hasField(@TypeOf(entity_def), "sprite")) {
                @compileError("Inline entity must have 'sprite' field");
            }

            const game = ctx.game;
            const sprite_def = entity_def.sprite;

            // Create ECS entity
            const entity = game.createEntity();

            // Add Position component
            game.addPosition(entity, Position{
                .x = getFieldOrDefault(sprite_def, "x", @as(f32, 0)),
                .y = getFieldOrDefault(sprite_def, "y", @as(f32, 0)),
            });

            // Add Sprite component
            try game.addSprite(entity, Sprite{
                .sprite_name = sprite_def.name,
                .z_index = getFieldOrDefault(sprite_def, "z_index", ZIndex.characters),
                .scale = getFieldOrDefault(sprite_def, "scale", @as(f32, 1.0)),
                .rotation = getFieldOrDefault(sprite_def, "rotation", @as(f32, 0)),
                .flip_x = getFieldOrDefault(sprite_def, "flip_x", false),
                .flip_y = getFieldOrDefault(sprite_def, "flip_y", false),
                .pivot = getFieldOrDefault(sprite_def, "pivot", render_pipeline_mod.Pivot.center),
                .pivot_x = getFieldOrDefault(sprite_def, "pivot_x", @as(f32, 0.5)),
                .pivot_y = getFieldOrDefault(sprite_def, "pivot_y", @as(f32, 0.5)),
            });

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(game.getRegistry(), entity, entity_def.components);
            }

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Load a shape entity
        fn loadShapeEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
        ) !EntityInstance {
            const shape_def = entity_def.shape;
            const game = ctx.game;

            // Create ECS entity
            const entity = game.createEntity();

            // Add Position component
            game.addPosition(entity, Position{
                .x = getFieldOrDefault(shape_def, "x", @as(f32, 0)),
                .y = getFieldOrDefault(shape_def, "y", @as(f32, 0)),
            });

            // Build shape based on type
            const shape_type = shape_def.type;
            var shape: Shape = switch (shape_type) {
                .circle => Shape.circle(getFieldOrDefault(shape_def, "radius", @as(f32, 10))),
                .rectangle => Shape.rectangle(
                    getFieldOrDefault(shape_def, "width", @as(f32, 10)),
                    getFieldOrDefault(shape_def, "height", @as(f32, 10)),
                ),
                .line => Shape.line(
                    getFieldOrDefault(shape_def, "end_x", @as(f32, 10)),
                    getFieldOrDefault(shape_def, "end_y", @as(f32, 0)),
                    getFieldOrDefault(shape_def, "thickness", @as(f32, 1)),
                ),
                else => @compileError("Unknown shape type in scene definition"),
            };

            // Color
            if (@hasField(@TypeOf(shape_def), "color")) {
                shape.color = .{
                    .r = shape_def.color.r,
                    .g = shape_def.color.g,
                    .b = shape_def.color.b,
                    .a = if (@hasField(@TypeOf(shape_def.color), "a")) shape_def.color.a else 255,
                };
            }

            // z_index
            if (@hasField(@TypeOf(shape_def), "z_index")) {
                shape.z_index = shape_def.z_index;
            }

            try game.addShape(entity, shape);

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(game.getRegistry(), entity, entity_def.components);
            }

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
