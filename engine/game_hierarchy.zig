// Entity hierarchy management — parent/child relationships, reparenting, cycle detection.
//
// This is a zero-bit field mixin for GameWith(Hooks). Methods access the parent
// Game struct via @fieldParentPtr("hierarchy", self).

const std = @import("std");
const ecs = @import("ecs");
const render_pipeline_mod = @import("../render/src/pipeline.zig");

const Entity = ecs.Entity;
const Registry = ecs.Registry;
const Allocator = std.mem.Allocator;
const RenderPipeline = render_pipeline_mod.RenderPipeline;
const Position = render_pipeline_mod.Position;
const Parent = render_pipeline_mod.Parent;
const Children = render_pipeline_mod.Children;

pub fn HierarchyMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        /// Hierarchy error types
        pub const HierarchyError = error{
            /// Cannot set an entity as its own parent
            SelfParenting,
            /// Setting this parent would create a cycle (child is ancestor of parent)
            CircularHierarchy,
            /// Hierarchy depth exceeds safety limit (32)
            HierarchyTooDeep,
        };

        fn game(self: *Self) *GameType {
            return @alignCast(@fieldParentPtr("hierarchy", self));
        }

        /// Set the parent of an entity, establishing a parent-child relationship.
        /// The child's Position becomes relative to the parent.
        /// Returns error if this would create a cycle or exceed depth limit.
        ///
        /// **Physics Warning**: Entities with RigidBody components should NOT be parented
        /// to other entities. Physics bodies operate in world space and don't support
        /// hierarchical transforms. If you need grouped physics objects, use physics
        /// joints/constraints instead. The physics module may log warnings or behave
        /// unexpectedly if RigidBody entities are placed in a hierarchy.
        pub fn setParent(self: *Self, child: Entity, new_parent: Entity) HierarchyError!void {
            const g = self.game();

            // Prevent self-parenting
            if (child == new_parent) {
                return HierarchyError.SelfParenting;
            }

            // Walk up ancestor chain to detect cycles
            var current = new_parent;
            var depth: u8 = 0;
            while (g.registry.tryGet(Parent, current)) |parent_comp| {
                if (parent_comp.entity == child) {
                    return HierarchyError.CircularHierarchy;
                }
                if (depth > 32) {
                    return HierarchyError.HierarchyTooDeep;
                }
                current = parent_comp.entity;
                depth += 1;
            }

            // Remove from old parent's children list if re-parenting
            if (g.registry.tryGet(Parent, child)) |old_parent_comp| {
                self.removeFromChildrenList(old_parent_comp.entity, child);
                // Update existing Parent component
                old_parent_comp.entity = new_parent;
                old_parent_comp.inherit_rotation = false;
                old_parent_comp.inherit_scale = false;
            } else {
                // Add new Parent component
                g.registry.add(child, Parent{ .entity = new_parent });
            }

            // Update cached hierarchy flag for the render pipeline
            g.pipeline.updateHierarchyFlag(child, true);

            // Add to new parent's children list
            self.addToChildrenList(new_parent, child);
        }

        /// Set parent with inheritance options.
        /// The child's local position is NOT adjusted.
        pub fn setParentWithOptions(
            self: *Self,
            child: Entity,
            new_parent: Entity,
            inherit_rotation: bool,
            inherit_scale: bool,
        ) HierarchyError!void {
            try self.setParent(child, new_parent);
            const g = self.game();
            // Update the Parent component with options
            if (g.registry.tryGet(Parent, child)) |parent_comp| {
                parent_comp.inherit_rotation = inherit_rotation;
                parent_comp.inherit_scale = inherit_scale;
            }
        }

        /// Set parent with inheritance options, preserving the child's visual world
        /// transform by recalculating its local offset (and rotation) from the new parent.
        pub fn setParentKeepTransform(
            self: *Self,
            child: Entity,
            new_parent: Entity,
            inherit_rotation: bool,
            inherit_scale: bool,
        ) HierarchyError!void {
            const g = self.game();

            // Save world transform before reparenting
            const saved_transform = g.pos.getWorldTransform(child);

            try self.setParentWithOptions(child, new_parent, inherit_rotation, inherit_scale);

            // Restore world transform by computing the required local offset
            if (saved_transform) |wt| {
                const pos = g.registry.tryGet(Position, child) orelse return;
                const parent_world = g.pos.computeWorldTransformInternal(new_parent, 0);
                const pw_x = if (parent_world) |pw| pw.x else 0;
                const pw_y = if (parent_world) |pw| pw.y else 0;
                const pw_rot = if (parent_world) |pw| pw.rotation else 0;

                // Compute local position offset from parent
                const offset_x = wt.x - pw_x;
                const offset_y = wt.y - pw_y;

                if (inherit_rotation and pw_rot != 0) {
                    const cos_r = @cos(-pw_rot);
                    const sin_r = @sin(-pw_rot);
                    pos.x = offset_x * cos_r - offset_y * sin_r;
                    pos.y = offset_x * sin_r + offset_y * cos_r;
                } else {
                    pos.x = offset_x;
                    pos.y = offset_y;
                }

                // Always restore rotation: when inheriting, subtract parent's rotation
                // to get local; when not inheriting, local rotation IS world rotation
                pos.rotation = if (inherit_rotation) wt.rotation - pw_rot else wt.rotation;

                g.pipeline.markPositionDirty(child);
            }
        }

        /// Remove the parent from an entity, making it a root entity.
        /// The entity's local position is NOT adjusted — it becomes the new world position.
        pub fn removeParent(self: *Self, child: Entity) void {
            self.removeParentInternal(child, false);
        }

        /// Remove the parent from an entity, preserving its visual world transform.
        /// The entity's local position (and rotation) are set to their world-space
        /// values so it stays visually in place after detaching.
        pub fn removeParentKeepTransform(self: *Self, child: Entity) void {
            self.removeParentInternal(child, true);
        }

        /// Internal: remove parent with optional world transform preservation.
        fn removeParentInternal(self: *Self, child: Entity, keep_world_transform: bool) void {
            const g = self.game();

            if (g.registry.tryGet(Parent, child)) |parent_comp| {
                // Save world transform before removing parent
                const saved_transform = if (keep_world_transform) g.pos.getWorldTransform(child) else null;

                // Remove from parent's children list
                self.removeFromChildrenList(parent_comp.entity, child);
                // Remove the Parent component
                g.registry.remove(Parent, child);

                // Update cached hierarchy flag for the render pipeline
                g.pipeline.updateHierarchyFlag(child, false);

                // Restore: for a root entity, local transform IS world transform
                if (saved_transform) |wt| {
                    if (g.registry.tryGet(Position, child)) |pos| {
                        pos.x = wt.x;
                        pos.y = wt.y;
                        pos.rotation = wt.rotation;
                    }
                }

                // Always mark dirty: the entity's world position changes when
                // detached (local becomes world) or when transform is restored
                g.pipeline.markPositionDirty(child);
            }
        }

        /// Get the parent entity, or null if this is a root entity
        pub fn getParent(self: *Self, entity: Entity) ?Entity {
            const g = self.game();
            if (g.registry.tryGet(Parent, entity)) |parent_comp| {
                return parent_comp.entity;
            }
            return null;
        }

        /// Get the children of an entity
        pub fn getChildren(self: *Self, entity: Entity) []const Entity {
            const g = self.game();
            if (g.registry.tryGet(Children, entity)) |children_comp| {
                return children_comp.entities;
            }
            return &.{};
        }

        /// Check if an entity has children
        pub fn hasChildren(self: *Self, entity: Entity) bool {
            const g = self.game();
            if (g.registry.tryGet(Children, entity)) |children_comp| {
                return children_comp.entities.len > 0;
            }
            return false;
        }

        /// Check if an entity is a root (has no parent)
        pub fn isRoot(self: *Self, entity: Entity) bool {
            const g = self.game();
            return g.registry.tryGet(Parent, entity) == null;
        }

        // Internal: Add child to parent's Children component
        fn addToChildrenList(self: *Self, parent_entity: Entity, child: Entity) void {
            const g = self.game();
            if (g.registry.tryGet(Children, parent_entity)) |children_comp| {
                // Allocate new slice with child added
                const old_entities = children_comp.entities;
                const new_entities = g.allocator.alloc(Entity, old_entities.len + 1) catch return;
                @memcpy(new_entities[0..old_entities.len], old_entities);
                new_entities[old_entities.len] = child;
                // Free old slice if it was allocated
                if (old_entities.len > 0) {
                    g.allocator.free(@constCast(old_entities));
                }
                children_comp.entities = new_entities;
            } else {
                // Create new Children component
                const new_entities = g.allocator.alloc(Entity, 1) catch return;
                new_entities[0] = child;
                g.registry.add(parent_entity, Children{ .entities = new_entities });
            }
        }

        // Internal: Remove child from parent's Children component
        fn removeFromChildrenList(self: *Self, parent_entity: Entity, child: Entity) void {
            const g = self.game();
            if (g.registry.tryGet(Children, parent_entity)) |children_comp| {
                const old_entities = children_comp.entities;
                if (old_entities.len == 0) return;

                // Find and remove child
                if (std.mem.indexOfScalar(Entity, old_entities, child)) |idx| {
                    if (old_entities.len == 1) {
                        // Last child, remove Children component
                        g.allocator.free(@constCast(old_entities));
                        g.registry.remove(Children, parent_entity);
                    } else {
                        // Allocate new slice without child
                        const new_entities = g.allocator.alloc(Entity, old_entities.len - 1) catch return;
                        @memcpy(new_entities[0..idx], old_entities[0..idx]);
                        @memcpy(new_entities[idx..], old_entities[idx + 1 ..]);
                        g.allocator.free(@constCast(old_entities));
                        children_comp.entities = new_entities;
                    }
                }
            }
        }
    };
}
