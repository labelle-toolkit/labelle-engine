// Sprite configuration and merging utilities
//
// This module provides:
// - SpriteConfig: A struct for sprite visual properties used in prefab merging
// - Merge utilities for combining prefab sprites with scene overrides
//
// The Sprite component itself is in components.zig, but this module handles
// the comptime configuration and merging logic for prefabs.

const std = @import("std");
const labelle = @import("labelle");

// Re-export types from labelle-gfx
pub const Pivot = labelle.Pivot;
pub const Layer = labelle.DefaultLayers;
pub const SizeMode = labelle.SizeMode;
pub const Container = labelle.Container;

// Z-index constants
pub const ZIndex = struct {
    pub const background: u8 = 0;
    pub const characters: u8 = 128;
    pub const foreground: u8 = 255;
};

/// Sprite configuration for prefabs (visual properties only, position is in Position component)
/// This is used for comptime prefab merging - the actual runtime component is Sprite in components.zig
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

    /// Helper to get a field value or default at comptime
    fn getFieldOrDefault(comptime data: anytype, comptime field_name: []const u8, comptime default: anytype) @TypeOf(default) {
        if (@hasField(@TypeOf(data), field_name)) {
            return @field(data, field_name);
        } else {
            return default;
        }
    }

    /// Parse container specification from comptime sprite data.
    /// Supports:
    ///   - Not present: returns null (default behavior)
    ///   - .infer: Container.infer
    ///   - .viewport: Container.viewport
    ///   - .camera_viewport: Container.camera_viewport
    ///   - .{ .width = W, .height = H }: Container.size(W, H)
    ///   - .{ .x = X, .y = Y, .width = W, .height = H }: Container.rect(X, Y, W, H)
    fn parseContainer(comptime sprite_data: anytype) ?Container {
        if (!@hasField(@TypeOf(sprite_data), "container")) {
            return null;
        }

        const container_data = sprite_data.container;
        const ContainerType = @TypeOf(container_data);

        // Check if it's one of the enum tags or an enum literal from .zon
        if (ContainerType == @TypeOf(Container.infer) or @typeInfo(ContainerType) == .enum_literal) {
            return @as(Container, container_data);
        }

        // Check if it's a struct with width/height (explicit container)
        if (@typeInfo(ContainerType) == .@"struct") {
            const has_width = @hasField(ContainerType, "width");
            const has_height = @hasField(ContainerType, "height");

            if (has_width and has_height) {
                const x = getFieldOrDefault(container_data, "x", @as(f32, 0));
                const y = getFieldOrDefault(container_data, "y", @as(f32, 0));
                return Container.rect(x, y, container_data.width, container_data.height);
            }
        }

        // Default to null if we can't parse it
        return null;
    }

    /// Build a SpriteConfig from comptime .zon data.
    /// Handles the .name field mapping and container parsing.
    ///
    /// Example .zon data:
    /// ```
    /// .{ .name = "player.png", .scale = 2.0, .pivot = .bottom_center }
    /// ```
    pub fn fromZonData(comptime sprite_data: anytype) SpriteConfig {
        // Handle .name field
        const name = if (@hasField(@TypeOf(sprite_data), "name"))
            sprite_data.name
        else
            "";

        return .{
            .name = name,
            .scale = getFieldOrDefault(sprite_data, "scale", @as(f32, 1.0)),
            .rotation = getFieldOrDefault(sprite_data, "rotation", @as(f32, 0)),
            .flip_x = getFieldOrDefault(sprite_data, "flip_x", false),
            .flip_y = getFieldOrDefault(sprite_data, "flip_y", false),
            .z_index = getFieldOrDefault(sprite_data, "z_index", ZIndex.characters),
            .pivot = getFieldOrDefault(sprite_data, "pivot", Pivot.center),
            .pivot_x = getFieldOrDefault(sprite_data, "pivot_x", @as(f32, 0.5)),
            .pivot_y = getFieldOrDefault(sprite_data, "pivot_y", @as(f32, 0.5)),
            .layer = getFieldOrDefault(sprite_data, "layer", Layer.world),
            .size_mode = getFieldOrDefault(sprite_data, "size_mode", SizeMode.none),
            .container = parseContainer(sprite_data),
        };
    }

    /// Merge this config with overrides, returning a new config.
    /// Used for prefab + scene override merging.
    pub fn merge(self: SpriteConfig, comptime overrides: anytype) SpriteConfig {
        var result = self;

        // Apply top-level overrides (scale, etc. directly on entity def)
        inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |field| {
            if (@hasField(SpriteConfig, field.name)) {
                @field(result, field.name) = @field(overrides, field.name);
            }
        }

        // Apply overrides from .components.Sprite if present
        if (@hasField(@TypeOf(overrides), "components")) {
            if (@hasField(@TypeOf(overrides.components), "Sprite")) {
                const sprite_overrides = overrides.components.Sprite;
                inline for (@typeInfo(@TypeOf(sprite_overrides)).@"struct".fields) |field| {
                    if (@hasField(SpriteConfig, field.name)) {
                        @field(result, field.name) = @field(sprite_overrides, field.name);
                    }
                }
                // Handle container specially since it needs parsing
                if (@hasField(@TypeOf(sprite_overrides), "container")) {
                    result.container = parseContainer(sprite_overrides);
                }
            }
        }

        return result;
    }
};

/// Get sprite config from prefab data, applying scene overrides.
/// This is the main entry point for prefab sprite merging.
///
/// Usage:
/// ```
/// const sprite_config = getMergedSpriteConfig(prefab_data.components.Sprite, entity_def);
/// ```
pub fn getMergedSpriteConfig(comptime prefab_sprite_data: anytype, comptime scene_overrides: anytype) SpriteConfig {
    const base = SpriteConfig.fromZonData(prefab_sprite_data);
    return base.merge(scene_overrides);
}
