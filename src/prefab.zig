// Prefab system - comptime struct templates with optional lifecycle hooks
//
// Prefabs are comptime structs that define:
// - sprite: Default sprite configuration
// - animation: Optional default animation to play
// - base: Optional reference to another prefab for composition
//
// Optional lifecycle hooks:
// - onCreate(entity, game): Called when entity is instantiated
// - onUpdate(entity, game, dt): Called every frame
// - onDestroy(entity, game): Called when entity is removed

const std = @import("std");
const labelle = @import("labelle");

// Re-export Pivot from labelle-gfx
pub const Pivot = labelle.Pivot;

// Z-index constants for backwards compatibility
pub const ZIndex = struct {
    pub const background: u8 = 0;
    pub const characters: u8 = 128;
    pub const foreground: u8 = 255;
};

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
    /// Pivot point for positioning and rotation (defaults to center)
    pivot: Pivot = .center,
    /// Custom pivot X coordinate (0.0-1.0), used when pivot == .custom
    pivot_x: f32 = 0.5,
    /// Custom pivot Y coordinate (0.0-1.0), used when pivot == .custom
    pivot_y: f32 = 0.5,
};

/// Type-erased prefab interface for runtime use
/// Uses u64 for entity and *anyopaque for Game to avoid circular imports.
/// The u64 type accommodates both 32-bit (zig_ecs) and 64-bit (zflecs) entity IDs.
pub const Prefab = struct {
    name: []const u8,
    sprite: SpriteConfig,
    animation: ?[]const u8,
    onCreate: ?*const fn (u64, *anyopaque) void,
    onUpdate: ?*const fn (u64, *anyopaque, f32) void,
    onDestroy: ?*const fn (u64, *anyopaque) void,
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
        .pivot = if (over.pivot != .center) over.pivot else base.pivot,
        .pivot_x = if (over.pivot_x != 0.5) over.pivot_x else base.pivot_x,
        .pivot_y = if (over.pivot_y != 0.5) over.pivot_y else base.pivot_y,
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
    if (@hasField(@TypeOf(overrides), "pivot")) {
        result.pivot = overrides.pivot;
    }
    if (@hasField(@TypeOf(overrides), "pivot_x")) {
        result.pivot_x = overrides.pivot_x;
    }
    if (@hasField(@TypeOf(overrides), "pivot_y")) {
        result.pivot_y = overrides.pivot_y;
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
        if (@hasField(@TypeOf(overrides.sprite), "pivot")) {
            result.pivot = overrides.sprite.pivot;
        }
        if (@hasField(@TypeOf(overrides.sprite), "pivot_x")) {
            result.pivot_x = overrides.sprite.pivot_x;
        }
        if (@hasField(@TypeOf(overrides.sprite), "pivot_y")) {
            result.pivot_y = overrides.sprite.pivot_y;
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

