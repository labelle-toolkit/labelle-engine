// Scene loader - loads scenes from comptime .zon data
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
//         .{ .prefab = "background" },
//         .{ .sprite = .{ .name = "coin.png", .x = 100, .y = 50 } },
//         .{ .sprite = .{ .name = "cloud.png" }, .components = .{ .Gravity = .{ .strength = 9.8 } } },
//         .{ .shape = .{ .type = .circle, .x = 100, .y = 100, .radius = 50, .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } } },
//         .{ .shape = .{ .type = .rectangle, .x = 200, .y = 200, .width = 100, .height = 50 } },
//     },
// }

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

pub const Prefab = prefab_mod.Prefab;
pub const SpriteConfig = prefab_mod.SpriteConfig;
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
    main = 0,     // Primary camera (camera 0)
    player2 = 1,  // Second player camera (camera 1)
    minimap = 2,  // Minimap/overview camera (camera 2)
    camera3 = 3,  // Fourth camera (camera 3)
};

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

/// Scene loader that combines .zon scene data with prefab, component, and script registries
pub fn SceneLoader(comptime PrefabRegistry: type, comptime Components: type, comptime Scripts: type) type {
    return struct {
        const Self = @This();

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

        /// Load an entity that references a prefab
        fn loadPrefabEntity(
            comptime entity_def: anytype,
            ctx: SceneContext,
        ) !EntityInstance {
            const prefab_data = PrefabRegistry.getComptime(entity_def.prefab);
            const game = ctx.game;

            // Create ECS entity
            const entity = game.createEntity();

            // Merge prefab sprite with any overrides from scene
            const sprite_config = prefab_mod.mergeSpriteWithOverrides(
                prefab_data.sprite,
                entity_def,
            );

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
            });

            // Call onCreate if defined
            if (prefab_data.onCreate) |create_fn| {
                create_fn(scene_mod.entityToU64(entity), @ptrCast(game));
            }

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(game.getRegistry(), entity, entity_def.components);
            }

            return .{
                .entity = entity,
                .visual_type = .sprite,
                .prefab_name = prefab_data.name,
                .onUpdate = prefab_data.onUpdate,
                .onDestroy = prefab_data.onDestroy,
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
            const x: f32 = if (@hasField(@TypeOf(sprite_def), "x")) sprite_def.x else 0;
            const y: f32 = if (@hasField(@TypeOf(sprite_def), "y")) sprite_def.y else 0;
            game.addPosition(entity, Position{ .x = x, .y = y });

            // Add Sprite component
            try game.addSprite(entity, Sprite{
                .sprite_name = sprite_def.name,
                .z_index = if (@hasField(@TypeOf(sprite_def), "z_index")) sprite_def.z_index else ZIndex.characters,
                .scale = if (@hasField(@TypeOf(sprite_def), "scale")) sprite_def.scale else 1.0,
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
            const x: f32 = if (@hasField(@TypeOf(shape_def), "x")) shape_def.x else 0;
            const y: f32 = if (@hasField(@TypeOf(shape_def), "y")) shape_def.y else 0;
            game.addPosition(entity, Position{ .x = x, .y = y });

            // Build shape based on type
            const shape_type = shape_def.type;
            var shape: Shape = switch (shape_type) {
                .circle => blk: {
                    const radius: f32 = if (@hasField(@TypeOf(shape_def), "radius")) shape_def.radius else 10;
                    break :blk Shape.circle(radius);
                },
                .rectangle => blk: {
                    const width: f32 = if (@hasField(@TypeOf(shape_def), "width")) shape_def.width else 10;
                    const height: f32 = if (@hasField(@TypeOf(shape_def), "height")) shape_def.height else 10;
                    break :blk Shape.rectangle(width, height);
                },
                .line => blk: {
                    const end_x: f32 = if (@hasField(@TypeOf(shape_def), "end_x")) shape_def.end_x else 10;
                    const end_y: f32 = if (@hasField(@TypeOf(shape_def), "end_y")) shape_def.end_y else 0;
                    const thickness: f32 = if (@hasField(@TypeOf(shape_def), "thickness")) shape_def.thickness else 1;
                    break :blk Shape.line(end_x, end_y, thickness);
                },
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

        /// Convenience function to load and return scene name
        pub fn loadScene(
            comptime scene_data: anytype,
            ctx: SceneContext,
        ) !Scene {
            return try load(scene_data, ctx);
        }
    };
}

