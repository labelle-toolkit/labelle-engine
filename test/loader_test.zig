const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const loader = engine.loader;
const prefab = engine.prefab;
const component = engine.component;
const script = engine.script;

test {
    zspec.runAll(@This());
}

// Test prefabs
const PlayerPrefab = struct {
    pub const name = "player";
    pub const sprite = prefab.SpriteConfig{
        .name = "player.png",
        .x = 100,
        .y = 200,
    };
};

const EnemyPrefab = struct {
    pub const name = "enemy";
    pub const sprite = prefab.SpriteConfig{
        .name = "enemy.png",
        .scale = 0.8,
    };
};

const BackgroundPrefab = struct {
    pub const name = "background";
    pub const sprite = prefab.SpriteConfig{
        .name = "background.png",
        .z_index = 0,
    };
};

// Test components
const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

// Test registries (without scripts to avoid circular dependency)
const TestPrefabs = prefab.PrefabRegistry(.{ PlayerPrefab, EnemyPrefab, BackgroundPrefab });
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
    };
};

pub const SCENE_DATA_FORMAT = struct {
    // Test scene definitions (compile-time verification)
    const simple_scene = .{
        .name = "simple",
        .entities = .{
            .{ .prefab = "player" },
        },
    };

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

    const scene_with_inline_sprites = .{
        .name = "with_inline",
        .entities = .{
            .{ .sprite = .{ .name = "coin.png", .x = 200, .y = 150 } },
            .{ .sprite = .{ .name = "platform.png" } },
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
                .sprite = .{ .name = "coin.png", .x = 500, .y = 200 },
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

        test "scene with inline sprites has two entities" {
            try expect.equal(scene_with_inline_sprites.entities.len, 2);
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

    pub const INLINE_SPRITES = struct {
        test "inline entity has sprite field" {
            const entity = scene_with_inline_sprites.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(entity), "sprite"));
        }

        test "inline sprite has name" {
            const entity = scene_with_inline_sprites.entities[0];
            try expect.toBeTrue(std.mem.eql(u8, entity.sprite.name, "coin.png"));
        }

        test "inline sprite can have position" {
            const entity = scene_with_inline_sprites.entities[0];
            try expect.equal(entity.sprite.x, 200);
            try expect.equal(entity.sprite.y, 150);
        }
    };
};

const loader_test = @This();
