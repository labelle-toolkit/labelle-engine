const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const loader = engine.scene.loader;
const prefab = engine.scene.prefab;
const component = engine.scene.component;
const script = engine.scene.script;

// Import factory definitions from .zon files
const prefab_defs = @import("factories/prefabs.zon");
const scene_defs = @import("factories/scenes.zon");

test {
    zspec.runAll(@This());
}

// Test components
const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

// Test registries using factory definitions
const TestPrefabs = prefab.PrefabRegistry(.{
    .player = prefab_defs.player,
    .enemy = prefab_defs.enemy,
    .background = prefab_defs.background,
});
const TestComponents = component.ComponentRegistry(struct {
    pub const Velocity = loader_test.Velocity;
    pub const Health = loader_test.Health;
});

pub const SCENE_LOADER = struct {
    pub const TYPE_CREATION = struct {
        test "SceneLoader function exists" {
            // Verify the SceneLoader function type exists
            try expect.toBeTrue(@hasDecl(loader, "SceneLoader"));
        }

        test "exports SceneLoader function" {
            try expect.toBeTrue(@TypeOf(loader.SceneLoader) != void);
        }
    };
};

pub const SCENE_DATA_FORMAT = struct {
    // Use scene definitions from .zon factory file
    const simple_scene = scene_defs.simple;
    const scene_with_camera = scene_defs.with_camera;

    // Additional test scene definitions that need specific structures
    const scene_with_scripts = .{
        .name = "with_scripts",
        .scripts = .{ "gravity", "movement" },
        .entities = .{
            .{ .prefab = "player" },
        },
    };

    const scene_with_overrides = .{
        .name = "with_overrides",
        .entities = .{
            .{ .prefab = "player", .x = 500, .y = 300 },
            .{ .prefab = "enemy", .x = 100 },
        },
    };

    const scene_with_components = .{
        .name = "with_components",
        .entities = .{
            .{
                .prefab = "player",
                .components = .{
                    .Velocity = .{ .x = 10, .y = 0 },
                    .Health = .{ .current = 50, .max = 100 },
                },
            },
        },
    };

    const scene_with_sprite_entities = .{
        .name = "with_sprites",
        .entities = .{
            .{ .x = 200, .y = 150, .components = .{ .Sprite = .{ .name = "coin.png" } } },
            .{ .components = .{ .Sprite = .{ .name = "platform.png" } } },
        },
    };

    const complex_scene = .{
        .name = "complex",
        .scripts = .{ "gravity", "movement" },
        .entities = .{
            .{ .prefab = "background" },
            .{
                .prefab = "player",
                .x = 400,
                .y = 300,
                .components = .{
                    .Velocity = .{},
                    .Health = .{ .current = 100, .max = 100 },
                },
            },
            .{
                .prefab = "enemy",
                .x = 600,
                .y = 300,
                .components = .{
                    .Health = .{ .current = 30, .max = 30 },
                },
            },
            .{
                .x = 500,
                .y = 200,
                .components = .{ .Sprite = .{ .name = "coin.png" } },
            },
        },
    };

    pub const SCENE_NAME = struct {
        test "simple scene has name" {
            try expect.toBeTrue(std.mem.eql(u8, simple_scene.name, "simple"));
        }

        test "scene with scripts has name" {
            try expect.toBeTrue(std.mem.eql(u8, scene_with_scripts.name, "with_scripts"));
        }

        test "complex scene has name" {
            try expect.toBeTrue(std.mem.eql(u8, complex_scene.name, "complex"));
        }
    };

    pub const SCENE_SCRIPTS = struct {
        test "scene without scripts field has no scripts" {
            try expect.toBeFalse(@hasField(@TypeOf(simple_scene), "scripts"));
        }

        test "scene with scripts has correct count" {
            try expect.equal(scene_with_scripts.scripts.len, 2);
        }

        test "complex scene has scripts" {
            try expect.equal(complex_scene.scripts.len, 2);
        }
    };

    pub const SCENE_ENTITIES = struct {
        test "simple scene has one entity" {
            try expect.equal(simple_scene.entities.len, 1);
        }

        test "scene with overrides has two entities" {
            try expect.equal(scene_with_overrides.entities.len, 2);
        }

        test "scene with sprite entities has two entities" {
            try expect.equal(scene_with_sprite_entities.entities.len, 2);
        }

        test "complex scene has four entities" {
            try expect.equal(complex_scene.entities.len, 4);
        }
    };

    pub const ENTITY_PREFAB = struct {
        test "entity can reference prefab by name" {
            const entity = simple_scene.entities[0];
            try expect.toBeTrue(std.mem.eql(u8, entity.prefab, "player"));
        }

        test "entity with overrides still has prefab reference" {
            const entity = scene_with_overrides.entities[0];
            try expect.toBeTrue(std.mem.eql(u8, entity.prefab, "player"));
        }
    };

    pub const ENTITY_OVERRIDES = struct {
        test "entity can have position overrides" {
            const entity = scene_with_overrides.entities[0];
            try expect.equal(entity.x, 500);
            try expect.equal(entity.y, 300);
        }

        test "entity can have partial overrides" {
            const entity = scene_with_overrides.entities[1];
            try expect.equal(entity.x, 100);
            try expect.toBeFalse(@hasField(@TypeOf(entity), "y"));
        }
    };

    pub const ENTITY_COMPONENTS = struct {
        test "entity can have components" {
            const entity = scene_with_components.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity), "components"));
        }

        test "component data is accessible" {
            const entity = scene_with_components.entities[0];
            try expect.equal(entity.components.Velocity.x, 10);
            try expect.equal(entity.components.Health.current, 50);
        }
    };

    pub const SPRITE_ENTITIES = struct {
        test "sprite entity has components.Sprite" {
            const entity = scene_with_sprite_entities.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity), "components"));
            try expect.toBeTrue(@hasField(@TypeOf(entity.components), "Sprite"));
        }

        test "sprite entity has name" {
            const entity = scene_with_sprite_entities.entities[0];
            try expect.toBeTrue(std.mem.eql(u8, entity.components.Sprite.name, "coin.png"));
        }

        test "sprite entity can have position at entity level" {
            const entity = scene_with_sprite_entities.entities[0];
            try expect.equal(entity.x, 200);
            try expect.equal(entity.y, 150);
        }
    };

    // Scene with Sprite defined inside .components block (uniform syntax)
    const scene_with_sprite_in_components = .{
        .name = "sprite_in_components",
        .entities = .{
            // Sprite inside components with entity-level position
            .{
                .x = 100,
                .y = 200,
                .components = .{
                    .Sprite = .{ .name = "player.png", .z_index = 10 },
                    .Health = .{ .current = 50 },
                },
            },
            // Sprite inside components with position in Sprite
            .{
                .components = .{
                    .Sprite = .{ .name = "enemy.png", .x = 300, .y = 400, .scale_x = 2.0, .scale_y = 2.0 },
                    .Velocity = .{ .x = 5, .y = 0 },
                },
            },
            // Sprite-only in components
            .{
                .components = .{
                    .Sprite = .{ .name = "item.png" },
                },
            },
        },
    };

    pub const SPRITE_IN_COMPONENTS = struct {
        test "entity can have Sprite in components" {
            const entity = scene_with_sprite_in_components.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity), "components"));
            try expect.toBeTrue(@hasField(@TypeOf(entity.components), "Sprite"));
        }

        test "Sprite in components has name" {
            const entity = scene_with_sprite_in_components.entities[0];
            try expect.toBeTrue(std.mem.eql(u8, entity.components.Sprite.name, "player.png"));
        }

        test "Sprite in components can have z_index" {
            const entity = scene_with_sprite_in_components.entities[0];
            try expect.equal(entity.components.Sprite.z_index, 10);
        }

        test "entity-level position overrides Sprite position" {
            const entity = scene_with_sprite_in_components.entities[0];
            try expect.equal(entity.x, 100);
            try expect.equal(entity.y, 200);
        }

        test "Sprite in components can have position" {
            const entity = scene_with_sprite_in_components.entities[1];
            try expect.equal(entity.components.Sprite.x, 300);
            try expect.equal(entity.components.Sprite.y, 400);
        }

        test "Sprite in components can have scale" {
            const entity = scene_with_sprite_in_components.entities[1];
            try expect.equal(entity.components.Sprite.scale_x, 2.0);
            try expect.equal(entity.components.Sprite.scale_y, 2.0);
        }

        test "can have other components alongside Sprite" {
            const entity = scene_with_sprite_in_components.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity.components), "Health"));
            try expect.equal(entity.components.Health.current, 50);
        }

        test "scene has correct entity count" {
            try expect.equal(scene_with_sprite_in_components.entities.len, 3);
        }
    };

    // Scene with data-only entities (no visual) - from factory
    const scene_with_data_only_entities = scene_defs.data_only;

    pub const DATA_ONLY_ENTITIES = struct {
        test "data-only entity has components but no visual" {
            const entity = scene_with_data_only_entities.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity), "components"));
            try expect.toBeFalse(@hasField(@TypeOf(entity.components), "Sprite"));
        }

        test "data-only entity can have components" {
            const entity = scene_with_data_only_entities.entities[0];
            try expect.equal(entity.components.Health.current, 100);
        }

        test "scene has correct entity count" {
            try expect.equal(scene_with_data_only_entities.entities.len, 1);
        }
    };
};

const loader_test = @This();
