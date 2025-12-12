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
        test "fields have sensible defaults" {
            const config = prefab.SpriteConfig{};
            try expect.equal(config.name.len, 0);
            try expect.equal(config.x, 0);
            try expect.equal(config.y, 0);
            try expect.equal(config.scale, 1.0);
            try expect.equal(config.rotation, 0);
            try expect.toBeFalse(config.flip_x);
            try expect.toBeFalse(config.flip_y);
            try expect.equal(config.pivot, .center);
            try expect.equal(config.pivot_x, 0.5);
            try expect.equal(config.pivot_y, 0.5);
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

        test "can set pivot" {
            const config = prefab.SpriteConfig{ .pivot = .bottom_center };
            try expect.equal(config.pivot, .bottom_center);
        }

        test "can set custom pivot coordinates" {
            const config = prefab.SpriteConfig{
                .pivot = .custom,
                .pivot_x = 0.25,
                .pivot_y = 0.75,
            };
            try expect.equal(config.pivot, .custom);
            try expect.equal(config.pivot_x, 0.25);
            try expect.equal(config.pivot_y, 0.75);
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

pub const MERGE_SPRITE_WITH_OVERRIDES = struct {
    pub const POSITION_OVERRIDES = struct {
        test "uses override x when specified" {
            const base = prefab.SpriteConfig{ .x = 10 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .x = 100 });
            try expect.equal(merged.x, 100);
        }

        test "uses base x when not overridden" {
            const base = prefab.SpriteConfig{ .x = 10 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.equal(merged.x, 10);
        }

        test "override can set x to zero" {
            const base = prefab.SpriteConfig{ .x = 10 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .x = 0 });
            try expect.equal(merged.x, 0);
        }

        test "uses override y when specified" {
            const base = prefab.SpriteConfig{ .y = 20 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .y = 200 });
            try expect.equal(merged.y, 200);
        }

        test "uses base y when not overridden" {
            const base = prefab.SpriteConfig{ .y = 20 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.equal(merged.y, 20);
        }
    };

    pub const SCALE_OVERRIDES = struct {
        test "uses override scale when specified" {
            const base = prefab.SpriteConfig{ .scale = 2.0 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .scale = 3.0 });
            try expect.equal(merged.scale, 3.0);
        }

        test "uses base scale when not overridden" {
            const base = prefab.SpriteConfig{ .scale = 2.0 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.equal(merged.scale, 2.0);
        }
    };

    pub const ROTATION_OVERRIDES = struct {
        test "uses override rotation when specified" {
            const base = prefab.SpriteConfig{ .rotation = 45 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .rotation = 90 });
            try expect.equal(merged.rotation, 90);
        }

        test "uses base rotation when not overridden" {
            const base = prefab.SpriteConfig{ .rotation = 45 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.equal(merged.rotation, 45);
        }
    };

    pub const FLIP_OVERRIDES = struct {
        test "flip_x uses override when specified" {
            const base = prefab.SpriteConfig{ .flip_x = false };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .flip_x = true });
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_x uses base when not overridden" {
            const base = prefab.SpriteConfig{ .flip_x = true };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.toBeTrue(merged.flip_x);
        }

        test "flip_y uses override when specified" {
            const base = prefab.SpriteConfig{ .flip_y = false };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .flip_y = true });
            try expect.toBeTrue(merged.flip_y);
        }

        test "flip_y uses base when not overridden" {
            const base = prefab.SpriteConfig{ .flip_y = true };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.toBeTrue(merged.flip_y);
        }
    };

    pub const PIVOT_OVERRIDES = struct {
        test "uses override pivot when specified" {
            const base = prefab.SpriteConfig{ .pivot = .top_left };
            const merged = prefab.mergeSpriteWithOverrides(base, .{ .pivot = .bottom_center });
            try expect.equal(merged.pivot, .bottom_center);
        }

        test "uses base pivot when not overridden" {
            const base = prefab.SpriteConfig{ .pivot = .bottom_center };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});
            try expect.equal(merged.pivot, .bottom_center);
        }
    };

    pub const NESTED_SPRITE_OVERRIDES = struct {
        test "uses nested sprite name override" {
            const base = prefab.SpriteConfig{ .name = "base.png" };
            const merged = prefab.mergeSpriteWithOverrides(base, .{
                .sprite = .{ .name = "over.png" },
            });
            try expect.toBeTrue(std.mem.eql(u8, merged.name, "over.png"));
        }

        test "uses nested sprite position override" {
            const base = prefab.SpriteConfig{ .x = 10, .y = 20 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{
                .sprite = .{ .x = 100, .y = 200 },
            });
            try expect.equal(merged.x, 100);
            try expect.equal(merged.y, 200);
        }

        test "uses nested sprite scale override" {
            const base = prefab.SpriteConfig{ .scale = 2.0 };
            const merged = prefab.mergeSpriteWithOverrides(base, .{
                .sprite = .{ .scale = 3.0 },
            });
            try expect.equal(merged.scale, 3.0);
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
            const merged = prefab.mergeSpriteWithOverrides(base, .{
                .x = 100,
                .rotation = 90,
                .flip_x = false,
                .flip_y = true,
            });

            try expect.toBeTrue(std.mem.eql(u8, merged.name, "base.png")); // preserved
            try expect.equal(merged.x, 100); // overridden
            try expect.equal(merged.y, 20); // preserved
            try expect.equal(merged.scale, 2.0); // preserved
            try expect.equal(merged.rotation, 90); // overridden
            try expect.toBeFalse(merged.flip_x); // overridden
            try expect.toBeTrue(merged.flip_y); // overridden
        }

        test "empty overrides preserve all base values" {
            const base = prefab.SpriteConfig{
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
            };
            const merged = prefab.mergeSpriteWithOverrides(base, .{});

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

pub const PREFAB_REGISTRY = struct {
    test "can create empty registry" {
        const allocator = std.testing.allocator;
        var registry = prefab.PrefabRegistry.init(allocator);
        defer registry.deinit();

        try expect.equal(registry.count(), 0);
    }

    test "get returns null for unknown prefab" {
        const allocator = std.testing.allocator;
        var registry = prefab.PrefabRegistry.init(allocator);
        defer registry.deinit();

        try expect.toBeNull(registry.get("unknown"));
    }

    test "has returns false for unknown prefab" {
        const allocator = std.testing.allocator;
        var registry = prefab.PrefabRegistry.init(allocator);
        defer registry.deinit();

        try expect.toBeFalse(registry.has("unknown"));
    }

    test "loadFolder handles missing directory gracefully" {
        const allocator = std.testing.allocator;
        var registry = prefab.PrefabRegistry.init(allocator);
        defer registry.deinit();

        // Should not error on missing directory
        try registry.loadFolder("nonexistent_directory");
        try expect.equal(registry.count(), 0);
    }
};

pub const ZINDEX = struct {
    test "background is lowest" {
        try expect.equal(prefab.ZIndex.background, 0);
    }

    test "characters is middle" {
        try expect.equal(prefab.ZIndex.characters, 128);
    }

    test "foreground is highest" {
        try expect.equal(prefab.ZIndex.foreground, 255);
    }
};

