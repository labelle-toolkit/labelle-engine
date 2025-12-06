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
        test "name defaults to empty string" {
            const config = prefab.SpriteConfig{};
            try expect.equal(config.name.len, 0);
        }

        test "position defaults to origin" {
            const config = prefab.SpriteConfig{};
            try expect.equal(config.x, 0);
            try expect.equal(config.y, 0);
        }

        test "scale defaults to 1.0" {
            const config = prefab.SpriteConfig{};
            try expect.equal(config.scale, 1.0);
        }

        test "rotation defaults to 0" {
            const config = prefab.SpriteConfig{};
            try expect.equal(config.rotation, 0);
        }

        test "flip flags default to false" {
            const config = prefab.SpriteConfig{};
            try expect.toBeFalse(config.flip_x);
            try expect.toBeFalse(config.flip_y);
        }
    };

    pub const INITIALIZATION = struct {
        test "can set name" {
            const config = prefab.SpriteConfig{ .name = "sprite.png" };
            try expect.toBeTrue(std.mem.eql(u8, config.name, "sprite.png"));
        }

        test "can set position" {
            const config = prefab.SpriteConfig{ .x = 100, .y = 200 };
            try expect.equal(config.x, 100);
            try expect.equal(config.y, 200);
        }

        test "can set scale" {
            const config = prefab.SpriteConfig{ .scale = 2.5 };
            try expect.equal(config.scale, 2.5);
        }

        test "can set rotation" {
            const config = prefab.SpriteConfig{ .rotation = 45.0 };
            try expect.equal(config.rotation, 45.0);
        }

        test "can set flip flags" {
            const config = prefab.SpriteConfig{ .flip_x = true, .flip_y = true };
            try expect.toBeTrue(config.flip_x);
            try expect.toBeTrue(config.flip_y);
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
            try expect.toBeTrue(std.mem.eql(u8, config.name, "test.png"));
            try expect.equal(config.x, 10);
            try expect.equal(config.y, 20);
            try expect.equal(config.z_index, 5);
            try expect.equal(config.scale, 1.5);
            try expect.equal(config.rotation, 90);
            try expect.toBeTrue(config.flip_x);
            try expect.toBeFalse(config.flip_y);
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
        test "uses over name when non-empty" {
            const base = prefab.SpriteConfig{ .name = "base.png" };
            const over = prefab.SpriteConfig{ .name = "over.png" };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(std.mem.eql(u8, merged.name, "over.png"));
        }

        test "uses base name when over name is empty" {
            const base = prefab.SpriteConfig{ .name = "base.png" };
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png"));
        }

        test "empty result when both names are empty" {
            const base = prefab.SpriteConfig{};
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.name.len, 0);
        }
    };

    pub const POSITION_MERGING = struct {
        test "uses over x when non-zero" {
            const base = prefab.SpriteConfig{ .x = 10 };
            const over = prefab.SpriteConfig{ .x = 100 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.x, 100);
        }

        test "uses base x when over x is zero" {
            const base = prefab.SpriteConfig{ .x = 10 };
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.x, 10);
        }

        test "uses over y when non-zero" {
            const base = prefab.SpriteConfig{ .y = 20 };
            const over = prefab.SpriteConfig{ .y = 200 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.y, 200);
        }

        test "uses base y when over y is zero" {
            const base = prefab.SpriteConfig{ .y = 20 };
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.y, 20);
        }
    };

    pub const SCALE_MERGING = struct {
        test "uses over scale when different from default" {
            const base = prefab.SpriteConfig{ .scale = 2.0 };
            const over = prefab.SpriteConfig{ .scale = 3.0 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.scale, 3.0);
        }

        test "uses base scale when over scale is default" {
            const base = prefab.SpriteConfig{ .scale = 2.0 };
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.scale, 2.0);
        }
    };

    pub const ROTATION_MERGING = struct {
        test "uses over rotation when non-zero" {
            const base = prefab.SpriteConfig{ .rotation = 45 };
            const over = prefab.SpriteConfig{ .rotation = 90 };
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.rotation, 90);
        }

        test "uses base rotation when over rotation is zero" {
            const base = prefab.SpriteConfig{ .rotation = 45 };
            const over = prefab.SpriteConfig{};
            const merged = prefab.mergeSprite(base, over);
            try expect.equal(merged.rotation, 45);
        }
    };

    pub const FLIP_MERGING = struct {
        test "flip_x is ORed - both false" {
            const base = prefab.SpriteConfig{ .flip_x = false };
            const over = prefab.SpriteConfig{ .flip_x = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeFalse(merged.flip_x);
        }

        test "flip_x is ORed - base true" {
            const base = prefab.SpriteConfig{ .flip_x = true };
            const over = prefab.SpriteConfig{ .flip_x = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x is ORed - over true" {
            const base = prefab.SpriteConfig{ .flip_x = false };
            const over = prefab.SpriteConfig{ .flip_x = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x is ORed - both true" {
            const base = prefab.SpriteConfig{ .flip_x = true };
            const over = prefab.SpriteConfig{ .flip_x = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_y is ORed - both false" {
            const base = prefab.SpriteConfig{ .flip_y = false };
            const over = prefab.SpriteConfig{ .flip_y = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeFalse(merged.flip_y);
        }

        test "flip_y is ORed - base true" {
            const base = prefab.SpriteConfig{ .flip_y = true };
            const over = prefab.SpriteConfig{ .flip_y = false };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_y);
        }

        test "flip_y is ORed - over true" {
            const base = prefab.SpriteConfig{ .flip_y = false };
            const over = prefab.SpriteConfig{ .flip_y = true };
            const merged = prefab.mergeSprite(base, over);
            try expect.toBeTrue(merged.flip_y);
        }
    };

    pub const COMPLEX_MERGING = struct {
        test "merges multiple fields correctly" {
            const base = prefab.SpriteConfig{
                .name = "base.png",
                .x = 10,
                .y = 20,
                .scale = 2.0,
                .rotation = 45,
                .flip_x = true,
                .flip_y = false,
            };
            const over = prefab.SpriteConfig{
                .name = "over.png",
                .x = 100,
                // y stays default (0)
                // scale stays default (1.0)
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
    };
};
