// Prefab system - comptime prefabs with typed components
//
// Prefabs are .zon files imported at comptime that define:
// - components.Position: Entity position (can be overridden in scene)
// - components.Sprite: Visual configuration for the entity
// - components.*: Other typed component data
//
// Example prefab file (prefabs/player.zon):
// .{
//     .components = .{
//         .Position = .{ .x = 0, .y = 0 },  // default position, can be overridden in scene
//         .Sprite = .{ .name = "player.png", .scale = 2.0 },
//         .Health = .{ .current = 100, .max = 100 },
//         .Speed = .{ .value = 5.0 },
//     },
// }

const std = @import("std");
const labelle = @import("labelle");

// Re-export Pivot from labelle-gfx
pub const Pivot = labelle.Pivot;

// Re-export layer types from labelle-gfx
pub const Layer = labelle.DefaultLayers;

// Re-export sizing types from labelle-gfx
pub const SizeMode = labelle.SizeMode;
pub const Container = labelle.Container;

// Z-index constants
pub const ZIndex = struct {
    pub const background: u8 = 0;
    pub const characters: u8 = 128;
    pub const foreground: u8 = 255;
};

/// Sprite configuration for prefabs (visual properties only, position is in Position component)
pub const SpriteConfig = struct {
    name: []const u8 = "",
    z_index: u8 = ZIndex.characters,
    scale: f32 = 1.0,
    rotation: f32 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    pivot: Pivot = .center,
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,
    /// Rendering layer (background, world, or ui)
    layer: Layer = .world,
    /// Sizing mode for container-based rendering (stretch, cover, contain, scale_down, repeat)
    size_mode: SizeMode = .none,
    /// Container specification for sized sprites (null = infer from layer space)
    container: ?Container = null,
};

/// Comptime prefab registry - maps prefab names to their comptime data
/// Usage:
///   const Prefabs = PrefabRegistry(.{
///       .player = @import("prefabs/player.zon"),
///       .enemy = @import("prefabs/enemy.zon"),
///   });
pub fn PrefabRegistry(comptime prefab_map: anytype) type {
    return struct {
        const Self = @This();
        const PrefabMap = @TypeOf(prefab_map);

        /// Check if a prefab exists
        pub fn has(comptime name: anytype) bool {
            const name_str: []const u8 = name;
            return @hasField(PrefabMap, name_str);
        }

        /// Get prefab data by name (comptime only)
        pub fn get(comptime name: []const u8) @TypeOf(@field(prefab_map, name)) {
            return @field(prefab_map, name);
        }

        /// Get sprite config from a prefab, applying overrides
        /// Sprite is expected in .components.Sprite
        pub fn getSprite(comptime name: []const u8, comptime overrides: anytype) SpriteConfig {
            const prefab_data = get(name);
            const base_sprite = if (@hasField(@TypeOf(prefab_data), "components") and
                @hasField(@TypeOf(prefab_data.components), "Sprite"))
                toSpriteConfig(prefab_data.components.Sprite)
            else
                SpriteConfig{};

            return mergeSpriteWithOverrides(base_sprite, overrides);
        }

        /// Convert comptime sprite data to SpriteConfig
        /// Only copies fields that exist in SpriteConfig (ignores unknown fields like x/y)
        fn toSpriteConfig(comptime data: anytype) SpriteConfig {
            var result = SpriteConfig{};
            inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |field| {
                if (@hasField(SpriteConfig, field.name)) {
                    @field(result, field.name) = @field(data, field.name);
                }
            }
            return result;
        }

        /// Check if prefab has components
        pub fn hasComponents(comptime name: []const u8) bool {
            const prefab_data = get(name);
            return @hasField(@TypeOf(prefab_data), "components");
        }

        /// Check if prefab has a Shape component (for shape-based prefabs)
        pub fn hasShape(comptime name: []const u8) bool {
            if (!hasComponents(name)) return false;
            const components = get(name).components;
            return @hasField(@TypeOf(components), "Shape");
        }

        /// Check if prefab has a Sprite component (for sprite-based prefabs)
        pub fn hasSprite(comptime name: []const u8) bool {
            if (!hasComponents(name)) return false;
            const components = get(name).components;
            return @hasField(@TypeOf(components), "Sprite");
        }

        /// Get prefab components data (for use with ComponentRegistry.addComponents)
        pub fn getComponents(comptime name: []const u8) @TypeOf(@field(get(name), "components")) {
            return get(name).components;
        }
    };
}

/// Apply overrides from a comptime struct to a result struct
fn applyOverrides(result: anytype, comptime overrides: anytype) void {
    inline for (@typeInfo(@TypeOf(result.*)).@"struct".fields) |field| {
        if (@hasField(@TypeOf(overrides), field.name)) {
            @field(result, field.name) = @field(overrides, field.name);
        }
    }
}

/// Merge sprite config with overrides from scene data
pub fn mergeSpriteWithOverrides(
    base: SpriteConfig,
    comptime overrides: anytype,
) SpriteConfig {
    var result = base;

    // Apply top-level overrides (x, y, scale, etc. directly on entity def)
    applyOverrides(&result, overrides);

    // Apply overrides from .components.Sprite if present
    if (@hasField(@TypeOf(overrides), "components") and @hasField(@TypeOf(overrides.components), "Sprite")) {
        applyOverrides(&result, overrides.components.Sprite);
    }

    return result;
}
