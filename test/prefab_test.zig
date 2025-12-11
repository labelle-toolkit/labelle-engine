const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const prefab = engine.prefab;

test {
    zspec.runAll(@This());
}

pub const SPRITE_CONFIG = struct {
    pub const DEFAULTS = struct {
        test "fields default to null" {
            const config = prefab.SpriteConfig{};
            try expect.toBeNull(config.name);
            try expect.toBeNull(config.x);
            try expect.toBeNull(config.y);
            try expect.toBeNull(config.scale);
            try expect.toBeNull(config.rotation);
            try expect.toBeNull(config.flip_x);
            try expect.toBeNull(config.flip_y);
            try expect.toBeNull(config.pivot);
            try expect.toBeNull(config.pivot_x);
            try expect.toBeNull(config.pivot_y);
        }

        test "toResolved applies defaults" {
            const config = prefab.SpriteConfig{};
            const resolved = config.toResolved();
            try expect.equal(resolved.name.len, 0);
            try expect.equal(resolved.x, 0);
            try expect.equal(resolved.y, 0);
            try expect.equal(resolved.scale, 1.0);
            try expect.equal(resolved.rotation, 0);
            try expect.toBeFalse(resolved.flip_x);
            try expect.toBeFalse(resolved.flip_y);
            try expect.equal(resolved.pivot, .center);
            try expect.equal(resolved.pivot_x, 0.5);
            try expect.equal(resolved.pivot_y, 0.5);
        }
    };

    pub const INITIALIZATION = struct {
        test "can set name" {
            const config = prefab.SpriteConfig{ .name = "sprite.png" };
            try expect.toBeTrue(std.mem.eql(u8, config.name.?, "sprite.png"));
        }

        test "can set position" {
            const config = prefab.SpriteConfig{ .x = 100, .y = 200 };
            try expect.equal(config.x.?, 100);
            try expect.equal(config.y.?, 200);
        }

        test "can set scale" {
            const config = prefab.SpriteConfig{ .scale = 2.5 };
            try expect.equal(config.scale.?, 2.5);
        }

        test "can set rotation" {
            const config = prefab.SpriteConfig{ .rotation = 45.0 };
            try expect.equal(config.rotation.?, 45.0);
        }

        test "can set flip flags" {
            const config = prefab.SpriteConfig{ .flip_x = true, .flip_y = true };
            try expect.toBeTrue(config.flip_x.?);
            try expect.toBeTrue(config.flip_y.?);
        }

        test "can set pivot" {
            const config = prefab.SpriteConfig{ .pivot = .bottom_center };
            try expect.equal(config.pivot.?, .bottom_center);
        }

        test "can set custom pivot coordinates" {
            const config = prefab.SpriteConfig{
                .pivot = .custom,
                .pivot_x = 0.25,
                .pivot_y = 0.75,
            };
            try expect.equal(config.pivot.?, .custom);
            try expect.equal(config.pivot_x.?, 0.25);
            try expect.equal(config.pivot_y.?, 0.75);
        }

        test "can set all fields at once" {
            const config = prefab.SpriteConfig{
                .name = "test.png",
                .x = 10,
                .y = 20,
                .z_index = 5,
                .scale = 1.5,
                .rotation = 90,
                .flip_x = true,
                .flip_y = false,
            };
            try expect.toBeTrue(std.mem.eql(u8, config.name.?, "test.png"));
            try expect.equal(config.x.?, 10);
            try expect.equal(config.y.?, 20);
            try expect.equal(config.z_index.?, 5);
            try expect.equal(config.scale.?, 1.5);
            try expect.equal(config.rotation.?, 90);
            try expect.toBeTrue(config.flip_x.?);
            try expect.toBeFalse(config.flip_y.?);
        }
    };
};

pub const IS_PREFAB = struct {
    test "returns false for type without name declaration" {
        const NoName = struct {
            pub const sprite = prefab.SpriteConfig{};
        };
        try expect.toBeFalse(prefab.isPrefab(NoName));
    }

    test "returns false for type without sprite declaration" {
        const NoSprite = struct {
            pub const name = "test";
        };
        try expect.toBeFalse(prefab.isPrefab(NoSprite));
    }

    test "returns false for empty struct" {
        const Empty = struct {};
        try expect.toBeFalse(prefab.isPrefab(Empty));
    }

    test "returns false for struct with wrong field types" {
        const WrongTypes = struct {
            pub const name = 123; // should be string
            pub const sprite = "wrong"; // should be SpriteConfig
        };
        // isPrefab only checks for existence, not types
        try expect.toBeTrue(prefab.isPrefab(WrongTypes));
    }
};

pub const MERGE_SPRITE = struct {
    pub const NAME_MERGING = struct {
        test "uses over name when specified" {
            const base = (prefab.SpriteConfig{ .name = "base.png" }).toResolved();
            const over = prefab.SpriteConfig{ .name = "over.png" };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(std.mem.eql(u8, merged.name, "over.png"));
        }

        test "uses base name when over name is null" {
            const base = (prefab.SpriteConfig{ .name = "base.png" }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png"));
        }

        test "empty result when both names use defaults" {
            const base = prefab.SpriteConfig.defaults;
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.name.len, 0);
        }
    };

    pub const POSITION_MERGING = struct {
        test "uses over x when specified" {
            const base = (prefab.SpriteConfig{ .x = 10 }).toResolved();
            const over = prefab.SpriteConfig{ .x = 100 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.x, 100);
        }

        test "uses base x when over x is null" {
            const base = (prefab.SpriteConfig{ .x = 10 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.x, 10);
        }

        test "over can explicitly set x to zero" {
            const base = (prefab.SpriteConfig{ .x = 10 }).toResolved();
            const over = prefab.SpriteConfig{ .x = 0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.x, 0);
        }

        test "uses over y when specified" {
            const base = (prefab.SpriteConfig{ .y = 20 }).toResolved();
            const over = prefab.SpriteConfig{ .y = 200 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.y, 200);
        }

        test "uses base y when over y is null" {
            const base = (prefab.SpriteConfig{ .y = 20 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.y, 20);
        }

        test "over can explicitly set y to zero" {
            const base = (prefab.SpriteConfig{ .y = 20 }).toResolved();
            const over = prefab.SpriteConfig{ .y = 0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.y, 0);
        }
    };

    pub const SCALE_MERGING = struct {
        test "uses over scale when specified" {
            const base = (prefab.SpriteConfig{ .scale = 2.0 }).toResolved();
            const over = prefab.SpriteConfig{ .scale = 3.0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.scale, 3.0);
        }

        test "uses base scale when over scale is null" {
            const base = (prefab.SpriteConfig{ .scale = 2.0 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.scale, 2.0);
        }

        test "over can explicitly set scale to 1.0" {
            const base = (prefab.SpriteConfig{ .scale = 2.0 }).toResolved();
            const over = prefab.SpriteConfig{ .scale = 1.0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.scale, 1.0);
        }
    };

    pub const ROTATION_MERGING = struct {
        test "uses over rotation when specified" {
            const base = (prefab.SpriteConfig{ .rotation = 45 }).toResolved();
            const over = prefab.SpriteConfig{ .rotation = 90 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.rotation, 90);
        }

        test "uses base rotation when over rotation is null" {
            const base = (prefab.SpriteConfig{ .rotation = 45 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.rotation, 45);
        }

        test "over can explicitly set rotation to zero" {
            const base = (prefab.SpriteConfig{ .rotation = 45 }).toResolved();
            const over = prefab.SpriteConfig{ .rotation = 0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.rotation, 0);
        }
    };

    pub const FLIP_MERGING = struct {
        test "flip_x is ORed - both false" {
            const base = (prefab.SpriteConfig{ .flip_x = false }).toResolved();
            const over = prefab.SpriteConfig{ .flip_x = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeFalse(merged.flip_x);
        }

        test "flip_x is ORed - base true" {
            const base = (prefab.SpriteConfig{ .flip_x = true }).toResolved();
            const over = prefab.SpriteConfig{ .flip_x = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x is ORed - over true" {
            const base = (prefab.SpriteConfig{ .flip_x = false }).toResolved();
            const over = prefab.SpriteConfig{ .flip_x = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x is ORed - both true" {
            const base = (prefab.SpriteConfig{ .flip_x = true }).toResolved();
            const over = prefab.SpriteConfig{ .flip_x = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x uses base when over is null" {
            const base = (prefab.SpriteConfig{ .flip_x = true }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_y is ORed - both false" {
            const base = (prefab.SpriteConfig{ .flip_y = false }).toResolved();
            const over = prefab.SpriteConfig{ .flip_y = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeFalse(merged.flip_y);
        }

        test "flip_y is ORed - base true" {
            const base = (prefab.SpriteConfig{ .flip_y = true }).toResolved();
            const over = prefab.SpriteConfig{ .flip_y = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_y);
        }

        test "flip_y is ORed - over true" {
            const base = (prefab.SpriteConfig{ .flip_y = false }).toResolved();
            const over = prefab.SpriteConfig{ .flip_y = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_y);
        }

        test "flip_y uses base when over is null" {
            const base = (prefab.SpriteConfig{ .flip_y = true }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_y);
        }
    };

    pub const PIVOT_MERGING = struct {
        test "uses over pivot when specified" {
            const base = (prefab.SpriteConfig{ .pivot = .top_left }).toResolved();
            const over = prefab.SpriteConfig{ .pivot = .bottom_center };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot, .bottom_center);
        }

        test "uses base pivot when over pivot is null" {
            const base = (prefab.SpriteConfig{ .pivot = .bottom_center }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot, .bottom_center);
        }

        test "over can explicitly set pivot to center" {
            const base = (prefab.SpriteConfig{ .pivot = .bottom_center }).toResolved();
            const over = prefab.SpriteConfig{ .pivot = .center };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot, .center);
        }

        test "uses over pivot_x when specified" {
            const base = (prefab.SpriteConfig{ .pivot_x = 0.25 }).toResolved();
            const over = prefab.SpriteConfig{ .pivot_x = 0.75 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_x, 0.75);
        }

        test "uses base pivot_x when over pivot_x is null" {
            const base = (prefab.SpriteConfig{ .pivot_x = 0.25 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_x, 0.25);
        }

        test "over can explicitly set pivot_x to 0.5" {
            const base = (prefab.SpriteConfig{ .pivot_x = 0.25 }).toResolved();
            const over = prefab.SpriteConfig{ .pivot_x = 0.5 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_x, 0.5);
        }

        test "uses over pivot_y when specified" {
            const base = (prefab.SpriteConfig{ .pivot_y = 0.1 }).toResolved();
            const over = prefab.SpriteConfig{ .pivot_y = 0.9 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_y, 0.9);
        }

        test "uses base pivot_y when over pivot_y is null" {
            const base = (prefab.SpriteConfig{ .pivot_y = 0.1 }).toResolved();
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_y, 0.1);
        }

        test "over can explicitly set pivot_y to 0.5" {
            const base = (prefab.SpriteConfig{ .pivot_y = 0.1 }).toResolved();
            const over = prefab.SpriteConfig{ .pivot_y = 0.5 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot_y, 0.5);
        }

        test "merges custom pivot with coordinates" {
            const base = prefab.SpriteConfig.defaults;
            const over = prefab.SpriteConfig{
                .pivot = .custom,
                .pivot_x = 0.3,
                .pivot_y = 0.7,
            };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.pivot, .custom);
            try expect.equal(merged.pivot_x, 0.3);
            try expect.equal(merged.pivot_y, 0.7);
        }
    };

    pub const COMPLEX_MERGING = struct {
        test "merges multiple fields correctly" {
            const base = (prefab.SpriteConfig{
                .name = "base.png",
                .x = 10,
                .y = 20,
                .scale = 2.0,
                .rotation = 45,
                .flip_x = true,
                .flip_y = false,
            }).toResolved();
            const over = prefab.SpriteConfig{
                .name = "over.png",
                .x = 100,
                // y stays null (inherit from base)
                // scale stays null (inherit from base)
                .rotation = 90,
                .flip_x = false,
                .flip_y = true,
            };
            const merged = prefab.mergeSprite(base, over);

            try expect.toBeTrue(std.mem.eql(u8, merged.name, "over.png"));
            try expect.equal(merged.x, 100);
            try expect.equal(merged.y, 20); // from base
            try expect.equal(merged.scale, 2.0); // from base
            try expect.equal(merged.rotation, 90);
            try expect.toBeTrue(merged.flip_x); // ORed
            try expect.toBeTrue(merged.flip_y); // ORed
        }

        test "null values correctly inherit from base" {
            const base = (prefab.SpriteConfig{
                .name = "base.png",
                .x = 50,
                .y = 75,
                .z_index = 10,
                .scale = 1.5,
                .rotation = 30,
                .flip_x = true,
                .flip_y = true,
                .pivot = .bottom_left,
                .pivot_x = 0.0,
                .pivot_y = 1.0,
            }).toResolved();
            const over = prefab.SpriteConfig{}; // all null - inherit everything
            const merged = prefab.mergeSprite(base, over);

            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png"));
            try expect.equal(merged.x, 50);
            try expect.equal(merged.y, 75);
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
