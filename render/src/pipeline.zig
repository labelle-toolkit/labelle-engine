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
pub const Parent = components.Parent;
pub const Children = components.Children;
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
    is_gizmo: bool = false, // Cached: entity has Gizmo component (avoids repeated tryGet)
    has_parent: bool = false, // Cached: entity has Parent component (position inheritance)
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

    /// Resolve the graphics (world) position for an entity.
    /// Handles:
    /// 1. Parent component - computes world position from hierarchy
    /// 2. Gizmo component - parent_position + gizmo_offset (legacy support)
    /// 3. Regular entity - uses entity's own position as world position
    fn resolveGfxPosition(registry: *Registry, entity: Entity) GfxPosition {
        // Check if entity has a Parent component (position inheritance)
        if (registry.tryGet(Parent, entity)) |parent_comp| {
            // Get local position of this entity
            const local_pos = if (registry.tryGet(Position, entity)) |p| p.* else Position{};

            // Recursively get parent's world position and rotation
            const parent_world = computeWorldTransform(registry, parent_comp.entity, 0);

            // Apply rotation if inherit_rotation is set
            if (parent_comp.inherit_rotation and parent_world.rotation != 0) {
                // Rotate local offset around parent's rotation
                const cos_r = @cos(parent_world.rotation);
                const sin_r = @sin(parent_world.rotation);
                const rotated_x = local_pos.x * cos_r - local_pos.y * sin_r;
                const rotated_y = local_pos.x * sin_r + local_pos.y * cos_r;
                return GfxPosition{
                    .x = parent_world.x + rotated_x,
                    .y = parent_world.y + rotated_y,
                };
            } else {
                // No rotation inheritance - simple offset
                return GfxPosition{
                    .x = parent_world.x + local_pos.x,
                    .y = parent_world.y + local_pos.y,
                };
            }
        }

        // Check if this is a gizmo with a parent entity (legacy gizmo support)
        if (registry.tryGet(Gizmo, entity)) |gizmo| {
            if (gizmo.parent_entity) |parent| {
                // Resolve position from parent + offset
                const parent_world = computeWorldTransform(registry, parent, 0);
                return GfxPosition{
                    .x = parent_world.x + gizmo.offset_x,
                    .y = parent_world.y + gizmo.offset_y,
                };
            }
        }

        // Regular entity - use its own position as world position
        if (registry.tryGet(Position, entity)) |pos| {
            return pos.toGfx();
        }

        // No position found
        return .{};
    }

    /// World transform result from hierarchy computation
    const WorldTransform = struct {
        x: f32 = 0,
        y: f32 = 0,
        rotation: f32 = 0,
        scale_x: f32 = 1,
        scale_y: f32 = 1,
    };

    /// Recursively compute world transform for an entity
    /// Traverses parent hierarchy to build cumulative transform
    fn computeWorldTransform(registry: *Registry, entity: Entity, depth: u8) WorldTransform {
        // Prevent infinite recursion from circular hierarchies
        if (depth > 32) {
            std.log.warn("Position hierarchy too deep (>32), possible cycle detected", .{});
            return .{};
        }

        // Get this entity's local position
        const local_pos = if (registry.tryGet(Position, entity)) |p| p.* else Position{};

        // Check if this entity has a parent
        if (registry.tryGet(Parent, entity)) |parent_comp| {
            // Recursively get parent's world transform
            const parent_world = computeWorldTransform(registry, parent_comp.entity, depth + 1);

            // Compute this entity's world position
            var world = WorldTransform{
                .rotation = local_pos.rotation,
                .scale_x = 1,
                .scale_y = 1,
            };

            // Apply rotation inheritance if enabled
            if (parent_comp.inherit_rotation) {
                world.rotation += parent_world.rotation;

                // Rotate local offset around parent's rotation
                const cos_r = @cos(parent_world.rotation);
                const sin_r = @sin(parent_world.rotation);
                world.x = parent_world.x + local_pos.x * cos_r - local_pos.y * sin_r;
                world.y = parent_world.y + local_pos.x * sin_r + local_pos.y * cos_r;
            } else {
                // No rotation - simple offset
                world.x = parent_world.x + local_pos.x;
                world.y = parent_world.y + local_pos.y;
            }

            // Apply scale inheritance if enabled
            if (parent_comp.inherit_scale) {
                world.scale_x = parent_world.scale_x;
                world.scale_y = parent_world.scale_y;
            }

            return world;
        }

        // Root entity - local position is world position
        return WorldTransform{
            .x = local_pos.x,
            .y = local_pos.y,
            .rotation = local_pos.rotation,
            .scale_x = 1,
            .scale_y = 1,
        };
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
                // Cache hierarchy flags (avoids repeated tryGet on every frame)
                tracked.is_gizmo = registry.tryGet(Gizmo, tracked.entity) != null;
                tracked.has_parent = registry.tryGet(Parent, tracked.entity) != null;

                // Resolve position - handles parent hierarchy and gizmo offsets
                const pos = resolveGfxPosition(registry, tracked.entity);

                var creation_succeeded = false;
                switch (tracked.visual_type) {
                    .none => {}, // No visual to create for data-only entities
                    .sprite => {
                        // Check for Sprite first, then Icon (which renders as sprite)
                        if (registry.tryGet(Sprite, tracked.entity)) |sprite| {
                            self.engine.createSprite(entity_id, sprite.toVisual(), pos);
                            creation_succeeded = true;
                        } else if (registry.tryGet(Icon, tracked.entity)) |icon| {
                            self.engine.createSprite(entity_id, icon.toVisual(), pos);
                            creation_succeeded = true;
                        } else {
                            std.log.warn("Entity tracked as sprite but missing Sprite/Icon component", .{});
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
                        // Check for Sprite first, then Icon (which renders as sprite)
                        if (registry.tryGet(Sprite, tracked.entity)) |sprite| {
                            self.engine.updateSprite(entity_id, sprite.toVisual());
                        } else if (registry.tryGet(Icon, tracked.entity)) |icon| {
                            self.engine.updateSprite(entity_id, icon.toVisual());
                        } else {
                            std.log.warn("Entity tracked as sprite but missing Sprite/Icon component during update", .{});
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
                    const pos = resolveGfxPosition(registry, tracked.entity);
                    self.engine.updatePosition(entity_id, pos);
                    tracked.position_dirty = false;
                }
            } else if (tracked.position_dirty and tracked.created) {
                // Only position changed - but only update if visual was created
                const pos = resolveGfxPosition(registry, tracked.entity);
                self.engine.updatePosition(entity_id, pos);
                tracked.position_dirty = false;
            } else if (tracked.created and (tracked.is_gizmo or tracked.has_parent)) {
                // Entities with parents (gizmos or parented): always update position
                // This ensures they follow their parent even when only the parent moves
                const pos = resolveGfxPosition(registry, tracked.entity);
                self.engine.updatePosition(entity_id, pos);
            }
        }
    }

    /// Get the number of tracked entities
    pub fn count(self: *const RenderPipeline) usize {
        return self.tracked.count();
    }
};
