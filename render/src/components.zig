//! Render Components
//!
//! User-facing components for visual rendering. These components are:
//! - Pure data (no runtime pointers)
//! - Serializable to .zon scene files
//! - Configured by the user, read by the render pipeline
//!
//! Each component has lifecycle callbacks (onAdd/onRemove) that automatically
//! register/unregister entities with the RenderPipeline.

const std = @import("std");
const graphics = @import("graphics");
const ecs = @import("ecs");

// Re-export graphics types via the interface (avoids module collisions)
pub const RetainedEngine = graphics.RetainedEngine;
pub const EntityId = graphics.EntityId;
pub const TextureId = graphics.TextureId;
pub const FontId = graphics.FontId;
pub const SpriteVisual = graphics.SpriteVisual;
pub const ShapeVisual = graphics.ShapeVisual;
pub const TextVisual = graphics.TextVisual;
pub const Color = graphics.Color;
pub const ShapeType = graphics.ShapeType;
pub const GfxPosition = graphics.Position;

// Layer system
pub const Layer = graphics.Layer;
pub const LayerConfig = graphics.LayerConfig;
pub const LayerSpace = graphics.LayerSpace;

// Sizing system
pub const SizeMode = graphics.SizeMode;
pub const Container = graphics.Container;

// Pivot system
pub const Pivot = graphics.Pivot;

// ECS types
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

// Hook types for lifecycle callbacks
pub const ComponentPayload = @import("../../hooks/types.zig").ComponentPayload;

// ============================================
// Position Component
// ============================================

/// Position component - stores LOCAL coordinates (offset from parent if parented)
///
/// When entity has a Parent component, Position is relative to parent.
/// World position = parent world position + rotated(local position)
///
/// Example in .zon:
/// ```
/// .Position = .{ .x = 100, .y = 200 },
/// .Position = .{ .x = 100, .y = 200, .rotation = 0.785 },  // 45 degrees
/// ```
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Rotation in radians (used by physics and rendering)
    rotation: f32 = 0,

    pub fn toGfx(self: Position) GfxPosition {
        return .{ .x = self.x, .y = self.y };
    }
};

// ============================================
// Parent Component (Position Inheritance)
// ============================================

/// Parent component - establishes parent-child hierarchy for position inheritance
///
/// When a Parent component is attached to an entity:
/// - The entity's Position becomes a local offset from the parent
/// - World position = parent world position + rotated(local position)
/// - Optionally inherits rotation from parent
///
/// Example in .zon:
/// ```
/// .Parent = .{ .entity = parent_entity_id },
/// .Parent = .{ .entity = parent_entity_id, .inherit_rotation = true },
/// ```
pub const Parent = struct {
    /// Reference to parent entity
    entity: Entity,
    /// Whether to inherit rotation from parent (default: false)
    inherit_rotation: bool = false,
    /// Whether to inherit scale from parent (default: false)
    inherit_scale: bool = false,
};

// ============================================
// Children Component (Position Inheritance)
// ============================================

/// Children component - tracks child entities for hierarchical operations
///
/// Automatically managed by the system when Parent components are added/removed.
/// Used for:
/// - Iterating over children
/// - Destroying children when parent is destroyed
/// - Propagating transform changes
///
/// Note: This is typically auto-populated, not set manually in .zon files.
pub const Children = struct {
    /// List of child entity IDs
    entities: []const Entity = &.{},
};

// ============================================
// Sprite Component
// ============================================

/// Sprite component - references a texture/sprite for rendering
///
/// Example in .zon:
/// ```
/// .Sprite = .{ .name = "player.png", .scale_x = 2.0, .scale_y = 2.0, .pivot = .bottom_center },
/// ```
pub const Sprite = struct {
    texture: TextureId = .invalid,
    /// Sprite name - matches texture/atlas sprite name for lookup
    name: []const u8 = "",
    /// Horizontal scale factor (1.0 = original size)
    scale_x: f32 = 1,
    /// Vertical scale factor (1.0 = original size)
    scale_y: f32 = 1,
    rotation: f32 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    tint: Color = Color.white,
    /// Z-index for depth ordering (-128 to 127, default 0)
    z_index: i16 = 0,
    visible: bool = true,
    /// Pivot point for positioning and rotation (defaults to center)
    pivot: Pivot = .center,
    /// Custom pivot X coordinate (0.0-1.0), used when pivot == .custom
    pivot_x: f32 = 0.5,
    /// Custom pivot Y coordinate (0.0-1.0), used when pivot == .custom
    pivot_y: f32 = 0.5,
    /// Rendering layer (background, world, or ui)
    layer: Layer = .world,
    /// Sizing mode for container-based rendering (stretch, cover, contain, scale_down, repeat)
    size_mode: SizeMode = .none,
    /// Container specification for sized sprites (null = infer from layer space)
    container: ?Container = null,

    pub fn toVisual(self: Sprite) SpriteVisual {
        return .{
            .texture = self.texture,
            .sprite_name = self.name,
            .scale_x = self.scale_x,
            .scale_y = self.scale_y,
            .rotation = self.rotation,
            .flip_x = self.flip_x,
            .flip_y = self.flip_y,
            .tint = self.tint,
            .z_index = self.z_index,
            .visible = self.visible,
            .pivot = self.pivot,
            .pivot_x = self.pivot_x,
            .pivot_y = self.pivot_y,
            .layer = self.layer,
            .size_mode = self.size_mode,
            .container = self.container,
        };
    }

    // ==================== Lifecycle Callbacks ====================
    // These are called by the ECS when the component is added/removed.
    // They automatically track/untrack the entity in the RenderPipeline.

    /// Called when Sprite component is added to an entity.
    /// Automatically tracks the entity in RenderPipeline for rendering.
    pub fn onAdd(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.trackEntity(entity, .sprite) catch |err| {
                std.log.err("Failed to track sprite entity: {}", .{err});
            };
        }
    }

    /// Called when Sprite component is removed from an entity.
    /// Automatically untracks the entity from RenderPipeline.
    pub fn onRemove(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.untrackEntity(entity);
        }
    }
};

// ============================================
// Shape Component
// ============================================

/// Shape component - renders geometric primitives
///
/// Example in .zon:
/// ```
/// .Shape = .{ .shape = .{ .circle = .{ .radius = 50 } }, .color = .{ .r = 255, .g = 0, .b = 0 } },
/// ```
pub const Shape = struct {
    shape: ShapeType,
    /// Horizontal scale factor (1.0 = original size)
    scale_x: f32 = 1,
    /// Vertical scale factor (1.0 = original size)
    scale_y: f32 = 1,
    color: Color = Color.white,
    rotation: f32 = 0,
    /// Z-index for depth ordering (-128 to 127, default 0)
    z_index: i16 = 0,
    visible: bool = true,
    /// Rendering layer (background, world, or ui)
    layer: Layer = .world,

    pub fn toVisual(self: Shape) ShapeVisual {
        return .{
            .shape = self.shape,
            .scale_x = self.scale_x,
            .scale_y = self.scale_y,
            .color = self.color,
            .rotation = self.rotation,
            .z_index = self.z_index,
            .visible = self.visible,
            .layer = self.layer,
        };
    }

    // Convenience constructors
    pub fn circle(radius: f32) Shape {
        return .{ .shape = .{ .circle = .{ .radius = radius } } };
    }

    pub fn rectangle(width: f32, height: f32) Shape {
        return .{ .shape = .{ .rectangle = .{ .width = width, .height = height } } };
    }

    pub fn line(end_x: f32, end_y: f32, thickness: f32) Shape {
        return .{ .shape = .{ .line = .{ .end = .{ .x = end_x, .y = end_y }, .thickness = thickness } } };
    }

    // ==================== Lifecycle Callbacks ====================

    /// Called when Shape component is added to an entity.
    pub fn onAdd(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.trackEntity(entity, .shape) catch |err| {
                std.log.err("Failed to track shape entity: {}", .{err});
            };
        }
    }

    /// Called when Shape component is removed from an entity.
    pub fn onRemove(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.untrackEntity(entity);
        }
    }
};

// ============================================
// Text Component
// ============================================

/// Text component - renders text with a font
///
/// Example in .zon:
/// ```
/// .Text = .{ .text = "Hello World", .size = 24 },
/// ```
pub const Text = struct {
    font: FontId = .invalid,
    text: [:0]const u8 = "",
    size: f32 = 16,
    color: Color = Color.white,
    /// Z-index for depth ordering (-128 to 127, default 0)
    z_index: i16 = 0,
    visible: bool = true,
    /// Rendering layer (background, world, or ui)
    layer: Layer = .world,

    pub fn toVisual(self: Text) TextVisual {
        return .{
            .font = self.font,
            .text = self.text,
            .size = self.size,
            .color = self.color,
            .z_index = self.z_index,
            .visible = self.visible,
            .layer = self.layer,
        };
    }

    // ==================== Lifecycle Callbacks ====================

    /// Called when Text component is added to an entity.
    pub fn onAdd(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.trackEntity(entity, .text) catch |err| {
                std.log.err("Failed to track text entity: {}", .{err});
            };
        }
    }

    /// Called when Text component is removed from an entity.
    pub fn onRemove(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.untrackEntity(entity);
        }
    }
};

// ============================================
// Visual Type Enum
// ============================================

pub const VisualType = enum {
    none, // Entity has no visual (e.g., nested data-only entities)
    sprite,
    shape,
    text,
};

// ============================================
// Component Registry Export
// ============================================

// Store file-level @This() for use in Components
const Self = @This();

/// Built-in render components for use with ComponentRegistryMulti.
/// Games can include this in their component registry to get Position, Sprite, Shape, Text.
// ============================================
// Gizmo Marker Component
// ============================================

/// Gizmo visibility modes
pub const GizmoVisibility = enum {
    /// Always show when gizmos are enabled
    always,
    /// Only show when parent entity is selected
    selected_only,
    /// Never show (disabled)
    never,
};

/// Gizmo marker component - marks an entity as a debug gizmo
///
/// Gizmos are debug-only visualizations that:
/// - Are only created in debug builds (stripped in release)
/// - Can be toggled on/off at runtime via game.setGizmosEnabled()
/// - Inherit position from their parent entity
///
/// Example in .zon:
/// ```
/// .{
///     .gizmos = .{
///         .Text = .{ .text = "Player", .size = 12 },
///         .Shape = .{ .shape = .{ .circle = .{ .radius = 5 } }, .color = .{ .r = 255 } },
///     },
///     .components = .{
///         .Position = .{ .x = 100, .y = 100 },
///         .Sprite = .{ .name = "player.png" },
///     },
/// }
/// ```
pub const Gizmo = struct {
    /// Reference to the parent entity this gizmo is attached to
    /// Optional because some ECS backends don't support Entity.invalid sentinel
    parent_entity: ?Entity = null,
    /// Offset from parent position
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// Visibility mode (always, selected_only, never)
    visibility: GizmoVisibility = .always,
    /// Group name for group-based toggling
    group: []const u8 = "",
};

// ============================================
// Icon Component (for gizmos)
// ============================================

/// Icon component - displays a small image marker (used for gizmo markers/waypoints)
///
/// Icon is a simplified sprite intended for debug visualizations like:
/// - Waypoint markers
/// - Spawn point indicators
/// - Debug indicators
///
/// Example in .zon:
/// ```
/// .gizmos = .{
///     .Icon = .{ .name = "waypoint_marker.png", .scale = 0.5 },
/// },
/// ```
pub const Icon = struct {
    texture: TextureId = .invalid,
    /// Sprite/texture name for lookup
    name: []const u8 = "",
    /// Uniform scale factor (1.0 = original size)
    scale: f32 = 1.0,
    tint: Color = Color.white,
    visible: bool = true,
    /// Z-index for depth ordering (-128 to 127, default 0)
    z_index: i16 = 0,
    /// Rendering layer (defaults to ui so it draws on top)
    layer: Layer = .ui,

    /// Convert Icon to Sprite for internal rendering
    pub fn toSprite(self: Icon) Sprite {
        return .{
            .texture = self.texture,
            .name = self.name,
            .scale_x = self.scale,
            .scale_y = self.scale,
            .tint = self.tint,
            .visible = self.visible,
            .z_index = self.z_index,
            .pivot = .center,
            .layer = self.layer,
        };
    }

    /// Convert to SpriteVisual for direct rendering
    pub fn toVisual(self: Icon) SpriteVisual {
        return self.toSprite().toVisual();
    }

    // ==================== Lifecycle Callbacks ====================

    /// Called when Icon component is added to an entity.
    pub fn onAdd(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.trackEntity(entity, .sprite) catch |err| {
                std.log.err("Failed to track icon entity: {}", .{err});
            };
        }
    }

    /// Called when Icon component is removed from an entity.
    pub fn onRemove(payload: ComponentPayload) void {
        const pipeline = @import("pipeline.zig");
        if (pipeline.getGlobalPipeline()) |p| {
            const entity = ecs.entityFromU64(payload.entity_id);
            p.untrackEntity(entity);
        }
    }
};

// ============================================
// BoundingBox Component (for gizmos)
// ============================================

/// BoundingBox gizmo component - draws a rectangle outline around an entity's visual bounds
///
/// Used for debugging to visualize entity bounds, collision areas, etc.
/// The bounding box is calculated from the parent entity's visual component (Sprite or Shape)
/// at runtime, so it automatically adapts to sprite dimensions from the texture atlas.
///
/// Example in .zon:
/// ```
/// .gizmos = .{
///     .BoundingBox = .{ .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 }, .padding = 2 },
/// },
/// ```
pub const BoundingBox = struct {
    /// Outline color
    color: Color = .{ .r = 0, .g = 255, .b = 0, .a = 200 },
    /// Padding around the visual bounds (in pixels)
    padding: f32 = 0,
    /// Line thickness for the outline
    thickness: f32 = 1,
    /// Whether to show the bounding box
    visible: bool = true,
    /// Z-index for rendering order (-128 to 127, default 127 to draw on top)
    z_index: i16 = 127, // Draw on top by default
    /// Rendering layer (defaults to ui so it draws on top)
    layer: Layer = .ui,

    /// Convert to a Shape component for a given width/height
    pub fn toShape(self: BoundingBox, width: f32, height: f32) Shape {
        return .{
            .shape = .{ .rectangle = .{
                .width = width + self.padding * 2,
                .height = height + self.padding * 2,
                .fill = .outline,
                .thickness = self.thickness,
            } },
            .color = self.color,
            .z_index = self.z_index,
            .visible = self.visible,
            .layer = self.layer,
        };
    }
};

pub const Components = struct {
    pub const Position = Self.Position;
    pub const Parent = Self.Parent;
    pub const Children = Self.Children;
    pub const Sprite = Self.Sprite;
    pub const Shape = Self.Shape;
    pub const Text = Self.Text;
    pub const Gizmo = Self.Gizmo;
    pub const GizmoVisibility = Self.GizmoVisibility;
    pub const Icon = Self.Icon;
    pub const BoundingBox = Self.BoundingBox;
};

// ============================================
// Tests
// ============================================

test "Position defaults" {
    const pos = Position{};
    try std.testing.expectEqual(@as(f32, 0), pos.x);
    try std.testing.expectEqual(@as(f32, 0), pos.y);
}

test "Sprite defaults" {
    const sprite = Sprite{};
    try std.testing.expectEqual(@as(f32, 1), sprite.scale_x);
    try std.testing.expectEqual(@as(f32, 1), sprite.scale_y);
    try std.testing.expectEqual(@as(f32, 0), sprite.rotation);
    try std.testing.expectEqual(@as(i16, 0), sprite.z_index);
    try std.testing.expect(!sprite.flip_x);
    try std.testing.expect(!sprite.flip_y);
    try std.testing.expect(sprite.visible);
    try std.testing.expectEqual(Pivot.center, sprite.pivot);
    try std.testing.expectEqual(Layer.world, sprite.layer);
}

test "Shape constructors" {
    const circ = Shape.circle(50);
    switch (circ.shape) {
        .circle => |c| try std.testing.expectEqual(@as(f32, 50), c.radius),
        else => unreachable,
    }

    const rect = Shape.rectangle(100, 50);
    switch (rect.shape) {
        .rectangle => |r| {
            try std.testing.expectEqual(@as(f32, 100), r.width);
            try std.testing.expectEqual(@as(f32, 50), r.height);
        },
        else => unreachable,
    }
}

test "Text defaults" {
    const text = Text{};
    try std.testing.expectEqual(@as(f32, 16), text.size);
    try std.testing.expect(text.visible);
    try std.testing.expectEqual(Layer.world, text.layer);
}
