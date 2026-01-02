const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const Factory = zspec.Factory;

const engine = @import("labelle-engine");
const prefab = engine.scene.prefab;
const render = engine.render;

// Import factory definitions from .zon files
const sprite_configs = @import("factories/sprite_configs.zon");
const prefab_defs = @import("factories/prefabs.zon");

test {
    zspec.runAll(@This());
}

// Define factories from .zon files (using render module's SpriteConfig)
const SpriteConfigFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.default);
const ScaledSpriteFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.scaled);
const FullSpriteFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.full);
const BaseMergeSpriteFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.base_for_merge);
const UiLayerSpriteFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.ui_layer);
const BackgroundLayerSpriteFactory = Factory.defineFrom(render.SpriteConfig, sprite_configs.background_layer);

pub const SPRITE_CONFIG = struct {
    pub const DEFAULTS = struct {
        test "fields have sensible defaults" {
            const config = SpriteConfigFactory.build(.{});
            try expect.equal(config.name.len, 0);
            try expect.equal(config.scale, 1.0);
            try expect.equal(config.rotation, 0);
            try expect.toBeFalse(config.flip_x);
            try expect.toBeFalse(config.flip_y);
            try expect.equal(config.pivot, .center);
            try expect.equal(config.pivot_x, 0.5);
            try expect.equal(config.pivot_y, 0.5);
        }

        test "layer defaults to world" {
            const config = SpriteConfigFactory.build(.{});
            try expect.equal(config.layer, .world);
        }
    };

    pub const INITIALIZATION = struct {
        test "can set name" {
            const config = SpriteConfigFactory.build(.{ .name = "sprite.png" });
            try expect.toBeTrue(std.mem.eql(u8, config.name, "sprite.png"));
        }

        test "can set scale" {
            const config = SpriteConfigFactory.build(.{ .scale = 2.5 });
            try expect.equal(config.scale, 2.5);
        }

        test "can set rotation" {
            const config = SpriteConfigFactory.build(.{ .rotation = 45.0 });
            try expect.equal(config.rotation, 45.0);
        }

        test "can set flip flags" {
            const config = SpriteConfigFactory.build(.{ .flip_x = true, .flip_y = true });
            try expect.toBeTrue(config.flip_x);
            try expect.toBeTrue(config.flip_y);
        }

        test "can set pivot" {
            const config = SpriteConfigFactory.build(.{ .pivot = .bottom_center });
            try expect.equal(config.pivot, .bottom_center);
        }

        test "can set custom pivot coordinates" {
            const config = SpriteConfigFactory.build(.{
                .pivot = .custom,
                .pivot_x = 0.25,
                .pivot_y = 0.75,
            });
            try expect.equal(config.pivot, .custom);
            try expect.equal(config.pivot_x, 0.25);
            try expect.equal(config.pivot_y, 0.75);
        }

        test "can set all fields at once" {
            const config = FullSpriteFactory.build(.{});
            try expect.toBeTrue(std.mem.eql(u8, config.name, "test.png"));
            try expect.equal(config.z_index, 5);
            try expect.equal(config.scale, 1.5);
            try expect.equal(config.rotation, 90);
            try expect.toBeTrue(config.flip_x);
            try expect.toBeFalse(config.flip_y);
        }

        test "can set layer to ui" {
            const config = UiLayerSpriteFactory.build(.{});
            try expect.equal(config.layer, .ui);
        }

        test "can set layer to background" {
            const config = BackgroundLayerSpriteFactory.build(.{});
            try expect.equal(config.layer, .background);
        }
    };
};

pub const SPRITE_CONFIG_MERGE = struct {
    pub const SCALE_OVERRIDES = struct {
        test "uses override scale when specified" {
            const base = ScaledSpriteFactory.build(.{});
            const merged = base.merge(.{ .scale = 3.0 });
            try expect.equal(merged.scale, 3.0);
        }

        test "uses base scale when not overridden" {
            const base = ScaledSpriteFactory.build(.{});
            const merged = base.merge(.{});
            try expect.equal(merged.scale, 2.0);
        }
    };

    pub const ROTATION_OVERRIDES = struct {
        test "uses override rotation when specified" {
            const base = SpriteConfigFactory.build(.{ .rotation = 45 });
            const merged = base.merge(.{ .rotation = 90 });
            try expect.equal(merged.rotation, 90);
        }

        test "uses base rotation when not overridden" {
            const base = SpriteConfigFactory.build(.{ .rotation = 45 });
            const merged = base.merge(.{});
            try expect.equal(merged.rotation, 45);
        }
    };

    pub const FLIP_OVERRIDES = struct {
        test "flip_x uses override when specified" {
            const base = SpriteConfigFactory.build(.{ .flip_x = false });
            const merged = base.merge(.{ .flip_x = true });
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x uses base when not overridden" {
            const base = SpriteConfigFactory.build(.{ .flip_x = true });
            const merged = base.merge(.{});
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_y uses override when specified" {
            const base = SpriteConfigFactory.build(.{ .flip_y = false });
            const merged = base.merge(.{ .flip_y = true });
            try expect.toBeTrue(merged.flip_y);
        }

        test "flip_y uses base when not overridden" {
            const base = SpriteConfigFactory.build(.{ .flip_y = true });
            const merged = base.merge(.{});
            try expect.toBeTrue(merged.flip_y);
        }
    };

    pub const PIVOT_OVERRIDES = struct {
        test "uses override pivot when specified" {
            const base = SpriteConfigFactory.build(.{ .pivot = .top_left });
            const merged = base.merge(.{ .pivot = .bottom_center });
            try expect.equal(merged.pivot, .bottom_center);
        }

        test "uses base pivot when not overridden" {
            const base = SpriteConfigFactory.build(.{ .pivot = .bottom_center });
            const merged = base.merge(.{});
            try expect.equal(merged.pivot, .bottom_center);
        }
    };

    pub const LAYER_OVERRIDES = struct {
        test "uses override layer when specified" {
            const base = SpriteConfigFactory.build(.{ .layer = .world });
            const merged = base.merge(.{ .layer = .ui });
            try expect.equal(merged.layer, .ui);
        }

        test "uses base layer when not overridden" {
            const base = UiLayerSpriteFactory.build(.{});
            const merged = base.merge(.{});
            try expect.equal(merged.layer, .ui);
        }

        test "can override to background layer" {
            const base = SpriteConfigFactory.build(.{});
            const merged = base.merge(.{ .layer = .background });
            try expect.equal(merged.layer, .background);
        }
    };

    pub const COMPLEX_MERGING = struct {
        test "merges multiple fields correctly" {
            const base = SpriteConfigFactory.build(.{
                .name = "base.png",
                .scale = 2.0,
                .rotation = 45,
                .flip_x = true,
                .flip_y = false,
            });
            const merged = base.merge(.{
                .rotation = 90,
                .flip_x = false,
                .flip_y = true,
            });

            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png")); // preserved
            try expect.equal(merged.scale, 2.0); // preserved
            try expect.equal(merged.rotation, 90); // overridden
            try expect.toBeFalse(merged.flip_x); // overridden
            try expect.toBeTrue(merged.flip_y); // overridden
        }

        test "empty overrides preserve all base values" {
            const base = BaseMergeSpriteFactory.build(.{});
            const merged = base.merge(.{});

            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png"));
            try expect.equal(merged.z_index, 10);
            try expect.equal(merged.scale, 1.5);
            try expect.equal(merged.rotation, 30);
            try expect.toBeTrue(merged.flip_x);
            try expect.toBeTrue(merged.flip_y);
            try expect.equal(merged.pivot, .bottom_left);
            try expect.equal(merged.pivot_x, 0.0);
            try expect.equal(merged.pivot_y, 1.0);
        }
    };
};

pub const PREFAB_REGISTRY = struct {
    // Use prefab definitions from .zon file
    const TestPrefabs = prefab.PrefabRegistry(.{
        .player = prefab_defs.player,
        .enemy = prefab_defs.enemy,
    });

    const EmptyPrefabs = prefab.PrefabRegistry(.{});

    test "empty registry has returns false" {
        try expect.toBeFalse(EmptyPrefabs.has("unknown"));
    }

    test "has returns true for registered prefab" {
        try expect.toBeTrue(TestPrefabs.has("player"));
        try expect.toBeTrue(TestPrefabs.has("enemy"));
    }

    test "has returns false for unknown prefab" {
        try expect.toBeFalse(TestPrefabs.has("unknown"));
    }

    test "get returns prefab data" {
        const player = TestPrefabs.get("player");
        try expect.toBeTrue(std.mem.eql(u8, player.components.Sprite.name, "player.png"));
        try expect.equal(player.components.Position.x, 100);
        try expect.equal(player.components.Position.y, 200);
    }

    test "hasComponents returns true when prefab has components" {
        try expect.toBeTrue(TestPrefabs.hasComponents("enemy"));
    }

    test "hasComponents returns true for prefab with only Sprite" {
        try expect.toBeTrue(TestPrefabs.hasComponents("player"));
    }

    test "getComponents returns component data" {
        const components = TestPrefabs.getComponents("enemy");
        try expect.equal(components.Health.current, 50);
        try expect.equal(components.Health.max, 50);
    }
};

pub const ZINDEX = struct {
    test "background is lowest" {
        try expect.equal(render.ZIndex.background, 0);
    }

    test "characters is middle" {
        try expect.equal(render.ZIndex.characters, 128);
    }

    test "foreground is highest" {
        try expect.equal(render.ZIndex.foreground, 255);
    }
};
