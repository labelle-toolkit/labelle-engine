// Render Pipeline - bridges ECS components to RetainedEngine
//
// This module provides:
// - Position component with dirty tracking
// - Sprite, Shape, Text components that wrap labelle-gfx visual types
// - RenderPipeline that syncs ECS state to RetainedEngine
//
// Usage:
//   var pipeline = RenderPipeline.init(allocator, &retained_engine);
//   defer pipeline.deinit();
//
//   // Create entity with position and sprite
//   const entity = registry.create();
//   registry.add(entity, Position{ .x = 100, .y = 200 });
//   registry.add(entity, Sprite{ .texture = tex_id });
//   pipeline.trackEntity(entity, .sprite);
//
//   // In game loop - sync dirty positions to gfx
//   pipeline.sync(&registry);

const std = @import("std");
const labelle = @import("labelle");
const ecs = @import("ecs");

// Re-export types from labelle-gfx
pub const RetainedEngine = labelle.RetainedEngine;
pub const EntityId = labelle.EntityId;
pub const TextureId = labelle.TextureId;
pub const FontId = labelle.FontId;
pub const SpriteVisual = labelle.SpriteVisual;
pub const ShapeVisual = labelle.ShapeVisual;
pub const TextVisual = labelle.TextVisual;
pub const Color = labelle.retained_engine.Color;

// ECS types
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

// ============================================
// Position Component
// ============================================

/// Position component - source of truth for entity location
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn toGfx(self: Position) labelle.retained_engine.Position {
        return .{ .x = self.x, .y = self.y };
    }
};

// ============================================
// Visual Components (wrap labelle-gfx types)
// ============================================

/// Sprite component - references a texture/sprite for rendering
pub const Sprite = struct {
    texture: TextureId = .invalid,
    sprite_name: []const u8 = "",
    scale: f32 = 1,
    rotation: f32 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    tint: Color = Color.white,
    z_index: u8 = 128,
    visible: bool = true,

    pub fn toVisual(self: Sprite) SpriteVisual {
        return .{
            .texture = self.texture,
            .sprite_name = self.sprite_name,
            .scale = self.scale,
            .rotation = self.rotation,
            .flip_x = self.flip_x,
            .flip_y = self.flip_y,
            .tint = self.tint,
            .z_index = self.z_index,
            .visible = self.visible,
        };
    }
};

/// Shape component - renders geometric primitives
pub const Shape = struct {
    shape: ShapeVisual.Shape,
    color: Color = Color.white,
    rotation: f32 = 0,
    z_index: u8 = 128,
    visible: bool = true,

    pub fn toVisual(self: Shape) ShapeVisual {
        return .{
            .shape = self.shape,
            .color = self.color,
            .rotation = self.rotation,
            .z_index = self.z_index,
            .visible = self.visible,
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
};

/// Text component - renders text with a font
pub const Text = struct {
    font: FontId = .invalid,
    text: [:0]const u8 = "",
    size: f32 = 16,
    color: Color = Color.white,
    z_index: u8 = 128,
    visible: bool = true,

    pub fn toVisual(self: Text) TextVisual {
        return .{
            .font = self.font,
            .text = self.text,
            .size = self.size,
            .color = self.color,
            .z_index = self.z_index,
            .visible = self.visible,
        };
    }
};

// ============================================
// Visual Type Enum
// ============================================

pub const VisualType = enum {
    sprite,
    shape,
    text,
};

// ============================================
// Tracked Entity
// ============================================

const TrackedEntity = struct {
    entity: Entity,
    visual_type: VisualType,
    position_dirty: bool = true,
    visual_dirty: bool = true,
};

// ============================================
// Render Pipeline
// ============================================

pub const RenderPipeline = struct {
    allocator: std.mem.Allocator,
    engine: *RetainedEngine,
    tracked: std.AutoArrayHashMap(Entity, TrackedEntity),

    pub fn init(allocator: std.mem.Allocator, engine: *RetainedEngine) RenderPipeline {
        return .{
            .allocator = allocator,
            .engine = engine,
            .tracked = std.AutoArrayHashMap(Entity, TrackedEntity).init(allocator),
        };
    }

    pub fn deinit(self: *RenderPipeline) void {
        self.tracked.deinit();
    }

    /// Convert ECS Entity to gfx EntityId
    fn toEntityId(entity: Entity) EntityId {
        return EntityId.from(@as(u32, @bitCast(entity)));
    }

    /// Start tracking an entity for rendering
    pub fn trackEntity(self: *RenderPipeline, entity: Entity, visual_type: VisualType) !void {
        try self.tracked.put(entity, .{
            .entity = entity,
            .visual_type = visual_type,
            .position_dirty = true,
            .visual_dirty = true,
        });
    }

    /// Stop tracking an entity and remove from renderer
    pub fn untrackEntity(self: *RenderPipeline, entity: Entity) void {
        if (self.tracked.fetchSwapRemove(entity)) |kv| {
            const entity_id = toEntityId(entity);
            switch (kv.value.visual_type) {
                .sprite => self.engine.destroySprite(entity_id),
                .shape => self.engine.destroyShape(entity_id),
                .text => self.engine.destroyText(entity_id),
            }
        }
    }

    /// Clear all tracked entities and destroy their visuals
    pub fn clear(self: *RenderPipeline) void {
        // Destroy all visuals in the engine
        var iter = self.tracked.iterator();
        while (iter.next()) |kv| {
            const entity_id = toEntityId(kv.key_ptr.*);
            switch (kv.value_ptr.visual_type) {
                .sprite => self.engine.destroySprite(entity_id),
                .shape => self.engine.destroyShape(entity_id),
                .text => self.engine.destroyText(entity_id),
            }
        }
        // Clear the tracking map
        self.tracked.clearRetainingCapacity();
    }

    /// Mark an entity's position as dirty (needs sync to gfx)
    pub fn markPositionDirty(self: *RenderPipeline, entity: Entity) void {
        if (self.tracked.getPtr(entity)) |tracked| {
            tracked.position_dirty = true;
        }
    }

    /// Mark an entity's visual data as dirty (needs sync to gfx)
    pub fn markVisualDirty(self: *RenderPipeline, entity: Entity) void {
        if (self.tracked.getPtr(entity)) |tracked| {
            tracked.visual_dirty = true;
        }
    }

    /// Sync all dirty entities to the RetainedEngine
    pub fn sync(self: *RenderPipeline, registry: *Registry) void {
        const GfxPosition = labelle.retained_engine.Position;

        for (self.tracked.values()) |*tracked| {
            const entity_id = toEntityId(tracked.entity);

            // Handle new/dirty visuals
            if (tracked.visual_dirty) {
                const pos: GfxPosition = if (registry.tryGet(Position, tracked.entity)) |p| p.toGfx() else .{};

                switch (tracked.visual_type) {
                    .sprite => {
                        if (registry.tryGet(Sprite, tracked.entity)) |sprite| {
                            // Destroy and recreate to handle visual changes
                            self.engine.destroySprite(entity_id);
                            self.engine.createSprite(entity_id, sprite.toVisual(), pos);
                        } else {
                            std.log.warn("Entity tracked as sprite but missing Sprite component", .{});
                        }
                    },
                    .shape => {
                        if (registry.tryGet(Shape, tracked.entity)) |shape| {
                            self.engine.destroyShape(entity_id);
                            self.engine.createShape(entity_id, shape.toVisual(), pos);
                        } else {
                            std.log.warn("Entity tracked as shape but missing Shape component", .{});
                        }
                    },
                    .text => {
                        if (registry.tryGet(Text, tracked.entity)) |text| {
                            self.engine.destroyText(entity_id);
                            self.engine.createText(entity_id, text.toVisual(), pos);
                        } else {
                            std.log.warn("Entity tracked as text but missing Text component", .{});
                        }
                    },
                }
                tracked.visual_dirty = false;
                tracked.position_dirty = false; // Position was set during create
            } else if (tracked.position_dirty) {
                // Only position changed
                if (registry.tryGet(Position, tracked.entity)) |pos| {
                    self.engine.updatePosition(entity_id, pos.toGfx());
                }
                tracked.position_dirty = false;
            }
        }
    }

    /// Get the number of tracked entities
    pub fn count(self: *const RenderPipeline) usize {
        return self.tracked.count();
    }
};

// ============================================
// Tests
// ============================================

test "Position component" {
    const pos = Position{ .x = 100, .y = 200 };
    const gfx_pos = pos.toGfx();
    try std.testing.expectEqual(@as(f32, 100), gfx_pos.x);
    try std.testing.expectEqual(@as(f32, 200), gfx_pos.y);
}

test "Sprite component" {
    const sprite = Sprite{ .scale = 2.0, .z_index = 50 };
    const visual = sprite.toVisual();
    try std.testing.expectEqual(@as(f32, 2.0), visual.scale);
    try std.testing.expectEqual(@as(u8, 50), visual.z_index);
}

test "Shape component constructors" {
    const circle = Shape.circle(50);
    try std.testing.expectEqual(@as(f32, 50), circle.shape.circle.radius);

    const rect = Shape.rectangle(100, 200);
    try std.testing.expectEqual(@as(f32, 100), rect.shape.rectangle.width);
    try std.testing.expectEqual(@as(f32, 200), rect.shape.rectangle.height);
}

test "RenderPipeline module compiles" {
    _ = RenderPipeline;
    _ = Position;
    _ = Sprite;
    _ = Shape;
    _ = Text;
}
