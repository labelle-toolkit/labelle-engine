// Prefab system - comptime struct templates with optional lifecycle hooks
//
// Prefabs are comptime structs that define:
// - sprite: Default sprite configuration
// - animation: Optional default animation to play
// - base: Optional reference to another prefab for composition
//
// Optional lifecycle hooks:
// - onCreate(sprite_id, engine): Called when entity is instantiated
// - onUpdate(sprite_id, engine, dt): Called every frame
// - onDestroy(sprite_id, engine): Called when entity is removed

const std = @import("std");
const labelle = @import("labelle");

pub const VisualEngine = labelle.VisualEngine;
pub const SpriteId = labelle.visual_engine.SpriteId;
pub const ZIndex = labelle.ZIndex;

/// Sprite configuration that can be defined in prefabs or scenes
pub const SpriteConfig = struct {
    name: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    z_index: u8 = ZIndex.characters,
    scale: f32 = 1.0,
    rotation: f32 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
};

/// Type-erased prefab interface for runtime use
pub const Prefab = struct {
    name: []const u8,
    sprite: SpriteConfig,
    animation: ?[]const u8,
    onCreate: ?*const fn (SpriteId, *VisualEngine) void,
    onUpdate: ?*const fn (SpriteId, *VisualEngine, f32) void,
    onDestroy: ?*const fn (SpriteId, *VisualEngine) void,
};

/// Check if a type is a valid prefab
pub fn isPrefab(comptime T: type) bool {
    // Must have a name
    if (!@hasDecl(T, "name")) return false;
    // Must have sprite config
    if (!@hasDecl(T, "sprite")) return false;
    return true;
}

/// Extract a Prefab from a comptime prefab type
pub fn fromType(comptime T: type) Prefab {
    if (!isPrefab(T)) {
        @compileError("Type is not a valid prefab. Must have 'name' and 'sprite' declarations.");
    }

    return .{
        .name = T.name,
        .sprite = getMergedSprite(T),
        .animation = if (@hasDecl(T, "animation")) T.animation else null,
        .onCreate = if (@hasDecl(T, "onCreate")) T.onCreate else null,
        .onUpdate = if (@hasDecl(T, "onUpdate")) T.onUpdate else null,
        .onDestroy = if (@hasDecl(T, "onDestroy")) T.onDestroy else null,
    };
}

/// Get merged sprite config, including base prefab if present
fn getMergedSprite(comptime T: type) SpriteConfig {
    if (@hasDecl(T, "base")) {
        const base_sprite = getMergedSprite(T.base);
        return mergeSprite(base_sprite, T.sprite);
    }
    return T.sprite;
}

/// Merge two sprite configs, with 'over' taking precedence
pub fn mergeSprite(base: SpriteConfig, over: SpriteConfig) SpriteConfig {
    return .{
        .name = if (over.name.len > 0) over.name else base.name,
        .x = if (over.x != 0) over.x else base.x,
        .y = if (over.y != 0) over.y else base.y,
        .z_index = if (over.z_index != ZIndex.characters) over.z_index else base.z_index,
        .scale = if (over.scale != 1.0) over.scale else base.scale,
        .rotation = if (over.rotation != 0) over.rotation else base.rotation,
        .flip_x = over.flip_x or base.flip_x,
        .flip_y = over.flip_y or base.flip_y,
    };
}

/// Merge sprite config with overrides from scene .zon data
pub fn mergeSpriteWithOverrides(
    base: SpriteConfig,
    comptime overrides: anytype,
) SpriteConfig {
    var result = base;

    // Check each possible override field
    if (@hasField(@TypeOf(overrides), "x")) {
        result.x = overrides.x;
    }
    if (@hasField(@TypeOf(overrides), "y")) {
        result.y = overrides.y;
    }
    if (@hasField(@TypeOf(overrides), "z_index")) {
        result.z_index = overrides.z_index;
    }
    if (@hasField(@TypeOf(overrides), "scale")) {
        result.scale = overrides.scale;
    }
    if (@hasField(@TypeOf(overrides), "rotation")) {
        result.rotation = overrides.rotation;
    }
    if (@hasField(@TypeOf(overrides), "flip_x")) {
        result.flip_x = overrides.flip_x;
    }
    if (@hasField(@TypeOf(overrides), "flip_y")) {
        result.flip_y = overrides.flip_y;
    }
    if (@hasField(@TypeOf(overrides), "sprite")) {
        if (@hasField(@TypeOf(overrides.sprite), "name")) {
            result.name = overrides.sprite.name;
        }
        if (@hasField(@TypeOf(overrides.sprite), "scale")) {
            result.scale = overrides.sprite.scale;
        }
        if (@hasField(@TypeOf(overrides.sprite), "z_index")) {
            result.z_index = overrides.sprite.z_index;
        }
    }

    return result;
}

/// Create a prefab registry from a tuple of prefab types
pub fn PrefabRegistry(comptime prefab_types: anytype) type {
    return struct {
        pub const prefabs = blk: {
            var arr: [prefab_types.len]Prefab = undefined;
            for (prefab_types, 0..) |T, i| {
                arr[i] = fromType(T);
            }
            break :blk arr;
        };

        pub fn get(name: []const u8) ?Prefab {
            inline for (prefabs) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    return p;
                }
            }
            return null;
        }

        pub fn getComptime(comptime name: []const u8) Prefab {
            inline for (prefabs) |p| {
                if (comptime std.mem.eql(u8, p.name, name)) {
                    return p;
                }
            }
            @compileError("Prefab not found: " ++ name);
        }
    };
}

test "prefab basics" {
    const TestPrefab = struct {
        pub const name = "test";
        pub const sprite = SpriteConfig{
            .name = "test.png",
            .x = 100,
            .y = 200,
        };
    };

    const p = fromType(TestPrefab);
    try std.testing.expectEqualStrings("test", p.name);
    try std.testing.expectEqualStrings("test.png", p.sprite.name);
    try std.testing.expectEqual(@as(f32, 100), p.sprite.x);
}

test "prefab with base" {
    const BasePrefab = struct {
        pub const name = "base";
        pub const sprite = SpriteConfig{
            .name = "base.png",
            .scale = 2.0,
            .z_index = ZIndex.background,
        };
    };

    const ChildPrefab = struct {
        pub const name = "child";
        pub const base = BasePrefab;
        pub const sprite = SpriteConfig{
            .name = "child.png", // override name
            // inherit scale and z_index from base
        };
    };

    const p = fromType(ChildPrefab);
    try std.testing.expectEqualStrings("child", p.name);
    try std.testing.expectEqualStrings("child.png", p.sprite.name);
    try std.testing.expectEqual(@as(f32, 2.0), p.sprite.scale);
    try std.testing.expectEqual(ZIndex.background, p.sprite.z_index);
}

test "prefab registry" {
    const Prefab1 = struct {
        pub const name = "player";
        pub const sprite = SpriteConfig{ .name = "player.png" };
    };

    const Prefab2 = struct {
        pub const name = "enemy";
        pub const sprite = SpriteConfig{ .name = "enemy.png" };
    };

    const Registry = PrefabRegistry(.{ Prefab1, Prefab2 });

    const player = Registry.get("player");
    try std.testing.expect(player != null);
    try std.testing.expectEqualStrings("player.png", player.?.sprite.name);

    const enemy = Registry.getComptime("enemy");
    try std.testing.expectEqualStrings("enemy.png", enemy.sprite.name);

    const unknown = Registry.get("unknown");
    try std.testing.expect(unknown == null);
}
