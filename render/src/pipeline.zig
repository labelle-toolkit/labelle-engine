//! Render Pipeline - bridges ECS components to RetainedEngine
//!
//! This module provides the RenderPipeline that syncs ECS state to the graphics backend.
//! Components are defined in components.zig.
//!
//! Usage:
//!   var pipeline = RenderPipeline.init(allocator, &retained_engine);
//!   defer pipeline.deinit();
//!
//!   // Create entity with position and sprite
//!   const entity = registry.create();
//!   registry.add(entity, Position{ .x = 100, .y = 200 });
//!   registry.add(entity, Sprite{ .texture = tex_id });
//!   // Sprite.onAdd callback automatically tracks the entity
//!
//!   // In game loop - sync dirty positions to gfx
//!   pipeline.sync(&registry);

const std = @import("std");
const graphics = @import("graphics");
const ecs = @import("ecs");
const components = @import("components.zig");

// Re-export component types
pub const Position = components.Position;
pub const Sprite = components.Sprite;
pub const Shape = components.Shape;
pub const Text = components.Text;
pub const Gizmo = components.Gizmo;
pub const GizmoVisibility = components.GizmoVisibility;
pub const Icon = components.Icon;
pub const BoundingBox = components.BoundingBox;
pub const VisualType = components.VisualType;
pub const Pivot = components.Pivot;
pub const GfxPosition = components.GfxPosition;

// Re-export backend types
pub const RetainedEngine = components.RetainedEngine;
pub const EntityId = components.EntityId;
pub const TextureId = components.TextureId;
pub const FontId = components.FontId;
pub const SpriteVisual = components.SpriteVisual;
pub const ShapeVisual = components.ShapeVisual;
pub const TextVisual = components.TextVisual;
pub const Color = components.Color;
pub const ShapeType = components.ShapeType;

// Re-export layer and sizing types
pub const Layer = components.Layer;
pub const LayerConfig = components.LayerConfig;
pub const LayerSpace = components.LayerSpace;
pub const SizeMode = components.SizeMode;
pub const Container = components.Container;

// ECS types
pub const Registry = components.Registry;
pub const Entity = components.Entity;

// ============================================
// Global Pipeline Access
// ============================================
// Used by component lifecycle callbacks (onAdd/onRemove) to access the pipeline.
// Set by Game.fixPointers().

var global_pipeline: ?*RenderPipeline = null;

/// Get the global pipeline pointer (for component callbacks).
/// Returns null if not yet initialized.
pub fn getGlobalPipeline() ?*RenderPipeline {
    return global_pipeline;
}

/// Set the global pipeline pointer.
/// Called by Game.fixPointers() after the Game struct is in its final location.
pub fn setGlobalPipeline(pipeline: ?*RenderPipeline) void {
    global_pipeline = pipeline;
}

// ============================================
// Tracked Entity
// ============================================

const TrackedEntity = struct {
    entity: Entity,
    visual_type: VisualType,
    position_dirty: bool = true,
    visual_dirty: bool = true,
    created: bool = false, // Has the visual been created in the engine?
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
    /// Uses the lower 32 bits of the entity ID for the graphics layer.
    /// This works for both 32-bit (zig_ecs) and 64-bit (zflecs) entities.
    fn toEntityId(entity: Entity) EntityId {
        const EntityBits = std.meta.Int(.unsigned, @bitSizeOf(Entity));
        const bits: EntityBits = @bitCast(entity);
        return EntityId.from(@truncate(bits));
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
                .none => {}, // No visual to destroy
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
                .none => {}, // No visual to destroy
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
        for (self.tracked.values()) |*tracked| {
            const entity_id = toEntityId(tracked.entity);

            // Handle new visuals (first time creation)
            if (!tracked.created) {
                const pos: GfxPosition = if (registry.tryGet(Position, tracked.entity)) |p| p.toGfx() else .{};

                var creation_succeeded = false;
                switch (tracked.visual_type) {
                    .none => {}, // No visual to create for data-only entities
                    .sprite => {
                        if (registry.tryGet(Sprite, tracked.entity)) |sprite| {
                            self.engine.createSprite(entity_id, sprite.toVisual(), pos);
                            creation_succeeded = true;
                        } else {
                            std.log.warn("Entity tracked as sprite but missing Sprite component", .{});
                        }
                    },
                    .shape => {
                        if (registry.tryGet(Shape, tracked.entity)) |shape| {
                            self.engine.createShape(entity_id, shape.toVisual(), pos);
                            creation_succeeded = true;
                        } else {
                            std.log.warn("Entity tracked as shape but missing Shape component", .{});
                        }
                    },
                    .text => {
                        if (registry.tryGet(Text, tracked.entity)) |text| {
                            self.engine.createText(entity_id, text.toVisual(), pos);
                            creation_succeeded = true;
                        } else {
                            std.log.warn("Entity tracked as text but missing Text component", .{});
                        }
                    },
                }
                // Only mark as created if creation actually succeeded
                // This prevents position updates on entities without visuals
                tracked.created = creation_succeeded;
                tracked.visual_dirty = false;
                tracked.position_dirty = false; // Position was set during create (or skipped if failed)
            } else if (tracked.visual_dirty) {
                // Visual changed - use update methods (v0.12.0+)
                switch (tracked.visual_type) {
                    .none => {}, // No visual to update for data-only entities
                    .sprite => {
                        if (registry.tryGet(Sprite, tracked.entity)) |sprite| {
                            self.engine.updateSprite(entity_id, sprite.toVisual());
                        } else {
                            std.log.warn("Entity tracked as sprite but missing Sprite component during update", .{});
                        }
                    },
                    .shape => {
                        if (registry.tryGet(Shape, tracked.entity)) |shape| {
                            self.engine.updateShape(entity_id, shape.toVisual());
                        } else {
                            std.log.warn("Entity tracked as shape but missing Shape component during update", .{});
                        }
                    },
                    .text => {
                        if (registry.tryGet(Text, tracked.entity)) |text| {
                            self.engine.updateText(entity_id, text.toVisual());
                        } else {
                            std.log.warn("Entity tracked as text but missing Text component during update", .{});
                        }
                    },
                }
                tracked.visual_dirty = false;
                // Also update position if dirty
                if (tracked.position_dirty) {
                    if (registry.tryGet(Position, tracked.entity)) |pos| {
                        self.engine.updatePosition(entity_id, pos.toGfx());
                    }
                    tracked.position_dirty = false;
                }
            } else if (tracked.position_dirty and tracked.created) {
                // Only position changed - but only update if visual was created
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
