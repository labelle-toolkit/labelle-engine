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

/// Sprite configuration with optional fields for merging/overriding.
/// Use null to indicate "not specified" (inherit from base).
/// Use `toResolved()` to get concrete values with defaults applied.
pub const SpriteConfig = struct {
    name: ?[]const u8 = null,
    x: ?f32 = null,
    y: ?f32 = null,
    z_index: ?u8 = null,
    scale: ?f32 = null,
    rotation: ?f32 = null,
    flip_x: ?bool = null,
    flip_y: ?bool = null,
    /// Pivot point for positioning and rotation
    pivot: ?Pivot = null,
    /// Custom pivot X coordinate (0.0-1.0), used when pivot == .custom
    pivot_x: ?f32 = null,
    /// Custom pivot Y coordinate (0.0-1.0), used when pivot == .custom
    pivot_y: ?f32 = null,

    /// Default values used when resolving null fields
    pub const defaults = ResolvedSpriteConfig{
        .name = "",
        .x = 0,
        .y = 0,
        .z_index = ZIndex.characters,
        .scale = 1.0,
        .rotation = 0,
        .flip_x = false,
        .flip_y = false,
        .pivot = .center,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    };

    /// Convert to resolved config with all defaults applied
    pub fn toResolved(self: SpriteConfig) ResolvedSpriteConfig {
        return .{
            .name = self.name orelse defaults.name,
            .x = self.x orelse defaults.x,
            .y = self.y orelse defaults.y,
            .z_index = self.z_index orelse defaults.z_index,
            .scale = self.scale orelse defaults.scale,
            .rotation = self.rotation orelse defaults.rotation,
            .flip_x = self.flip_x orelse defaults.flip_x,
            .flip_y = self.flip_y orelse defaults.flip_y,
            .pivot = self.pivot orelse defaults.pivot,
            .pivot_x = self.pivot_x orelse defaults.pivot_x,
            .pivot_y = self.pivot_y orelse defaults.pivot_y,
        };
    }
};

/// Resolved sprite configuration with concrete values (no optionals).
/// This is the final output after merging and applying defaults.
pub const ResolvedSpriteConfig = struct {
    name: []const u8,
    x: f32,
    y: f32,
    z_index: u8,
    scale: f32,
    rotation: f32,
    flip_x: bool,
    flip_y: bool,
    pivot: Pivot,
    pivot_x: f32,
    pivot_y: f32,
};

/// Type-erased prefab interface for runtime use
/// Uses u64 for entity and *anyopaque for Game to avoid circular imports.
/// The u64 type accommodates both 32-bit (zig_ecs) and 64-bit (zflecs) entity IDs.
pub const Prefab = struct {
    name: []const u8,
    sprite: ResolvedSpriteConfig,
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
fn getMergedSprite(comptime T: type) ResolvedSpriteConfig {
    if (@hasDecl(T, "base")) {
        const base_resolved = getMergedSprite(T.base);
        return mergeSprite(base_resolved, T.sprite);
    }
    return T.sprite.toResolved();
}

/// Merge a resolved base config with optional overrides.
/// For each field, if the override is non-null, use it; otherwise keep the base value.
pub fn mergeSprite(base: ResolvedSpriteConfig, over: SpriteConfig) ResolvedSpriteConfig {
    return .{
        .name = over.name orelse base.name,
        .x = over.x orelse base.x,
        .y = over.y orelse base.y,
        .z_index = over.z_index orelse base.z_index,
        .scale = over.scale orelse base.scale,
        .rotation = over.rotation orelse base.rotation,
        .flip_x = over.flip_x orelse base.flip_x,
        .flip_y = over.flip_y orelse base.flip_y,
        .pivot = over.pivot orelse base.pivot,
        .pivot_x = over.pivot_x orelse base.pivot_x,
        .pivot_y = over.pivot_y orelse base.pivot_y,
    };
}

/// Apply overrides from a comptime struct to a ResolvedSpriteConfig
/// Used by mergeSpriteWithOverrides to avoid code duplication
fn applySpriteOverrides(result: *ResolvedSpriteConfig, comptime over: anytype) void {
    if (@hasField(@TypeOf(over), "name")) {
        result.name = over.name;
    }
    if (@hasField(@TypeOf(over), "x")) {
        result.x = over.x;
    }
    if (@hasField(@TypeOf(over), "y")) {
        result.y = over.y;
    }
    if (@hasField(@TypeOf(over), "z_index")) {
        result.z_index = over.z_index;
    }
    if (@hasField(@TypeOf(over), "scale")) {
        result.scale = over.scale;
    }
    if (@hasField(@TypeOf(over), "rotation")) {
        result.rotation = over.rotation;
    }
    if (@hasField(@TypeOf(over), "flip_x")) {
        result.flip_x = over.flip_x;
    }
    if (@hasField(@TypeOf(over), "flip_y")) {
        result.flip_y = over.flip_y;
    }
    if (@hasField(@TypeOf(over), "pivot")) {
        result.pivot = over.pivot;
    }
    if (@hasField(@TypeOf(over), "pivot_x")) {
        result.pivot_x = over.pivot_x;
    }
    if (@hasField(@TypeOf(over), "pivot_y")) {
        result.pivot_y = over.pivot_y;
    }
}

/// Merge sprite config with overrides from scene .zon data
pub fn mergeSpriteWithOverrides(
    base: ResolvedSpriteConfig,
    comptime overrides: anytype,
) ResolvedSpriteConfig {
    var result = base;

    // Apply top-level overrides (e.g., .x = 100, .pivot = .bottom_center)
    applySpriteOverrides(&result, overrides);

    // Apply nested sprite overrides (e.g., .sprite = .{ .name = "foo.png" })
    if (@hasField(@TypeOf(overrides), "sprite")) {
        applySpriteOverrides(&result, overrides.sprite);
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

