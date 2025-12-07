// Scene loader - loads scenes from comptime .zon data
//
// Scene .zon format:
// .{
//     .name = "level1",
//     .scripts = .{ "gravity", "floating" },  // optional
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
const labelle = @import("labelle");
const ecs = @import("ecs");
const prefab_mod = @import("prefab.zig");
const scene_mod = @import("scene.zig");
const component_mod = @import("component.zig");
const script_mod = @import("script.zig");

pub const VisualEngine = labelle.VisualEngine;
pub const SpriteId = labelle.visual_engine.SpriteId;
pub const ShapeId = labelle.visual_engine.ShapeId;
pub const ShapeConfig = labelle.visual_engine.ShapeConfig;
pub const ShapeType = labelle.visual_engine.ShapeType;
pub const ZIndex = labelle.ZIndex;
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

pub const Prefab = prefab_mod.Prefab;
pub const SpriteConfig = prefab_mod.SpriteConfig;
pub const Scene = scene_mod.Scene;
pub const SceneContext = scene_mod.SceneContext;
pub const EntityInstance = scene_mod.EntityInstance;
pub const VisualType = scene_mod.VisualType;

/// Scene loader that combines .zon scene data with prefab, component, and script registries
pub fn SceneLoader(comptime PrefabRegistry: type, comptime Components: type, comptime Scripts: type) type {
    return struct {
        const Self = @This();

        /// Load a scene from comptime .zon data
        pub fn load(
            comptime scene_data: anytype,
            ctx: SceneContext,
        ) !Scene {
            // Get script update functions if scene has scripts defined
            const script_fns = comptime if (@hasField(@TypeOf(scene_data), "scripts"))
                Scripts.getUpdateFns(scene_data.scripts)
            else
                &[_]script_mod.UpdateFn{};

            var scene = Scene.init(scene_data.name, script_fns, ctx);
            errdefer scene.deinit();

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

            // Create ECS entity
            const entity = ctx.registry.create();

            // Merge prefab sprite with any overrides from scene
            const sprite_config = prefab_mod.mergeSpriteWithOverrides(
                prefab_data.sprite,
                entity_def,
            );

            // Add sprite to engine
            const sprite_id = try ctx.engine.addSprite(.{
                .sprite_name = sprite_config.name,
                .x = sprite_config.x,
                .y = sprite_config.y,
                .z_index = sprite_config.z_index,
                .scale = sprite_config.scale,
            });

            // Play default animation if defined
            if (prefab_data.animation) |anim| {
                _ = ctx.engine.play(sprite_id, anim);
            }

            // Call onCreate if defined
            if (prefab_data.onCreate) |create_fn| {
                create_fn(sprite_id, ctx.engine);
            }

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(ctx.registry, entity, entity_def.components);
            }

            return .{
                .entity = entity,
                .sprite_id = sprite_id,
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

            // Create ECS entity
            const entity = ctx.registry.create();

            const sprite_def = entity_def.sprite;

            const sprite_id = try ctx.engine.addSprite(.{
                .sprite_name = sprite_def.name,
                .x = if (@hasField(@TypeOf(sprite_def), "x")) sprite_def.x else 0,
                .y = if (@hasField(@TypeOf(sprite_def), "y")) sprite_def.y else 0,
                .z_index = if (@hasField(@TypeOf(sprite_def), "z_index")) sprite_def.z_index else ZIndex.characters,
                .scale = if (@hasField(@TypeOf(sprite_def), "scale")) sprite_def.scale else 1.0,
            });

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(ctx.registry, entity, entity_def.components);
            }

            return .{
                .entity = entity,
                .sprite_id = sprite_id,
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

            // Create ECS entity
            const entity = ctx.registry.create();

            // Determine shape type
            const shape_type: ShapeType = shape_def.type;

            // Build ShapeConfig
            var config = ShapeConfig{
                .shape_type = shape_type,
                .x = if (@hasField(@TypeOf(shape_def), "x")) shape_def.x else 0,
                .y = if (@hasField(@TypeOf(shape_def), "y")) shape_def.y else 0,
                .filled = if (@hasField(@TypeOf(shape_def), "filled")) shape_def.filled else true,
            };

            // Shape-specific properties
            if (@hasField(@TypeOf(shape_def), "radius")) {
                config.radius = shape_def.radius;
            }
            if (@hasField(@TypeOf(shape_def), "width")) {
                config.width = shape_def.width;
            }
            if (@hasField(@TypeOf(shape_def), "height")) {
                config.height = shape_def.height;
            }

            // Color
            if (@hasField(@TypeOf(shape_def), "color")) {
                config.color = .{
                    .r = shape_def.color.r,
                    .g = shape_def.color.g,
                    .b = shape_def.color.b,
                    .a = if (@hasField(@TypeOf(shape_def.color), "a")) shape_def.color.a else 255,
                };
            }

            const shape_id = try ctx.engine.addShape(config);

            // Add components from scene definition
            if (@hasField(@TypeOf(entity_def), "components")) {
                Components.addComponents(ctx.registry, entity, entity_def.components);
            }

            return .{
                .entity = entity,
                .visual_type = .shape,
                .shape_id = shape_id,
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

test "loader compiles" {
    // Just verify the module compiles
    _ = SceneLoader;
}
