// Position management — local position, world transform, hierarchy-aware positioning.
//
// This is a zero-bit field mixin for GameWith(Hooks). Methods access the parent
// Game struct via @fieldParentPtr("pos", self).

const std = @import("std");
const ecs = @import("ecs");
const render_pipeline_mod = @import("../../render/src/pipeline.zig");

const Entity = ecs.Entity;
const Position = render_pipeline_mod.Position;
const Parent = render_pipeline_mod.Parent;

pub fn PositionMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        /// World transform result from hierarchy computation
        pub const WorldTransform = struct {
            x: f32 = 0,
            y: f32 = 0,
            rotation: f32 = 0,
            scale_x: f32 = 1,
            scale_y: f32 = 1,
        };

        fn game(self: *Self) *GameType {
            return @alignCast(@fieldParentPtr("pos", self));
        }

        fn gameConst(self: *const Self) *const GameType {
            return @alignCast(@fieldParentPtr("pos", self));
        }

        /// Add Position component to an entity (local coordinates)
        pub fn addPosition(self: *Self, entity: Entity, position: Position) void {
            self.game().registry.add(entity, position);
        }

        // ── Local Position API ────────────────────────────────────

        /// Get local Position component (relative to parent, or world if no parent)
        pub fn getLocalPosition(self: *Self, entity: Entity) ?*Position {
            return self.game().registry.tryGet(Position, entity);
        }

        /// Set local Position component (marks dirty for sync)
        pub fn setLocalPosition(self: *Self, entity: Entity, position: Position) void {
            const g = self.game();
            if (g.registry.tryGet(Position, entity)) |p| {
                p.* = position;
                g.pipeline.markPositionDirty(entity);
            }
        }

        /// Set local Position using x, y coordinates directly (marks dirty for sync)
        pub fn setLocalPositionXY(self: *Self, entity: Entity, x: f32, y: f32) void {
            const g = self.game();
            if (g.registry.tryGet(Position, entity)) |p| {
                p.x = x;
                p.y = y;
                g.pipeline.markPositionDirty(entity);
            }
        }

        /// Move local Position by delta values (marks dirty for sync)
        pub fn moveLocalPosition(self: *Self, entity: Entity, dx: f32, dy: f32) void {
            const g = self.game();
            if (g.registry.tryGet(Position, entity)) |p| {
                p.x += dx;
                p.y += dy;
                g.pipeline.markPositionDirty(entity);
            }
        }

        // ── World Position API ────────────────────────────────────

        /// Get full world transform by computing through parent chain.
        /// Handles rotation and scale inheritance according to Parent component flags.
        /// Returns null if entity has no Position component.
        pub fn getWorldTransform(self: *Self, entity: Entity) ?WorldTransform {
            return self.computeWorldTransformInternal(entity, 0);
        }

        /// Recursive world transform computation (pub for cross-mixin access)
        pub fn computeWorldTransformInternal(self: *Self, entity: Entity, depth: u8) ?WorldTransform {
            const g = self.game();

            // Prevent infinite recursion from circular hierarchies
            if (depth > 32) {
                std.log.warn("Position hierarchy too deep (>32), possible cycle detected", .{});
                return null;
            }

            // Get this entity's local position
            const local_pos = g.registry.tryGet(Position, entity) orelse return null;

            // Check if this entity has a parent
            const parent_comp = g.registry.tryGet(Parent, entity) orelse {
                // No parent - local position IS world position
                return WorldTransform{
                    .x = local_pos.x,
                    .y = local_pos.y,
                    .rotation = local_pos.rotation,
                    .scale_x = 1,
                    .scale_y = 1,
                };
            };

            // Recursively get parent's world transform
            const parent_world = self.computeWorldTransformInternal(parent_comp.entity, depth + 1) orelse {
                return WorldTransform{
                    .x = local_pos.x,
                    .y = local_pos.y,
                    .rotation = local_pos.rotation,
                    .scale_x = 1,
                    .scale_y = 1,
                };
            };

            // Compute this entity's world transform
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

        /// Get world position by computing transform through parent chain.
        /// Returns null if entity has no Position component.
        pub fn getWorldPosition(self: *Self, entity: Entity) ?struct { x: f32, y: f32 } {
            const transform = self.getWorldTransform(entity) orelse return null;
            return .{ .x = transform.x, .y = transform.y };
        }

        /// Set world position by computing required local position.
        /// Adjusts local position so that world position matches the given coordinates.
        pub fn setWorldPosition(self: *Self, entity: Entity, world_x: f32, world_y: f32) void {
            const g = self.game();
            const pos = g.registry.tryGet(Position, entity) orelse return;

            // If no parent, local position IS world position
            const parent_comp = g.registry.tryGet(Parent, entity) orelse {
                pos.x = world_x;
                pos.y = world_y;
                g.pipeline.markPositionDirty(entity);
                return;
            };

            // Get parent's world transform to compute required local offset
            const parent_world = self.computeWorldTransformInternal(parent_comp.entity, 0) orelse {
                pos.x = world_x;
                pos.y = world_y;
                g.pipeline.markPositionDirty(entity);
                return;
            };

            // Compute offset from parent in world space
            const offset_x = world_x - parent_world.x;
            const offset_y = world_y - parent_world.y;

            // If inheriting rotation, apply inverse rotation to get local offset
            if (parent_comp.inherit_rotation and parent_world.rotation != 0) {
                const cos_r = @cos(-parent_world.rotation);
                const sin_r = @sin(-parent_world.rotation);
                pos.x = offset_x * cos_r - offset_y * sin_r;
                pos.y = offset_x * sin_r + offset_y * cos_r;
            } else {
                // No rotation - simple offset
                pos.x = offset_x;
                pos.y = offset_y;
            }

            g.pipeline.markPositionDirty(entity);
        }

        /// Set world position using x, y coordinates directly.
        pub fn setWorldPositionXY(self: *Self, entity: Entity, x: f32, y: f32) void {
            self.setWorldPosition(entity, x, y);
        }
    };
}
