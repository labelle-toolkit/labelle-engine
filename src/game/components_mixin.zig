/// Components mixin — position, parent/child hierarchy, and generic
/// component access (add / set / get / setField / has / remove / fireOnReady),
/// plus the preview-mode `notifyComponentChanged` telemetry helper.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. Intra-cluster
/// calls use lexical sibling-function syntax (`setPosition(self, ...)`) so
/// they resolve inside this struct rather than round-tripping through the
/// `Game` re-export — except `assertEntityAlive`, which stays on `Game`
/// (tombstone-guard cluster) and is reached via `self.assertEntityAlive`.
const std = @import("std");
const core = @import("labelle-core");
const Position = core.Position;
const hooks_types = @import("../hooks_types.zig");
const ComponentPayload = hooks_types.ComponentPayload;
const hierarchy = @import("hierarchy.zig");

/// Returns the components/hierarchy mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const EcsImpl = Game.EcsBackend;
    const Parent = Game.ParentComp;
    const Children = Game.ChildrenComp;

    return struct {
        pub fn setPosition(self: *Game, entity: Entity, pos: Position) void {
            self.ecs_backend.addComponent(entity, pos);
            self.renderer.markPositionDirtyWithChildren(EcsImpl, self.ecs_backend, entity);
            notifyComponentChanged(self, entity, pos);
        }

        /// Preview-mode helper. No-op unless `self.preview` is set AND
        /// the editor has subscribed to this component's name. Folded
        /// out by the compiler in non-preview builds because the
        /// `preview` field defaults to `null`.
        ///
        /// Generic over the component type so it can be called from
        /// any setter site without forcing the caller to spell out
        /// `@typeName` + `std.mem.asBytes` boilerplate. The
        /// subscription check runs first so `comp` is never read in
        /// the common "nobody's watching" path.
        pub inline fn notifyComponentChanged(self: *Game, entity: Entity, comp: anytype) void {
            if (self.preview) |*p| {
                // Callers may pass either a value or a `*T` (the
                // generic `addComponent` / `setComponent` accept
                // `anytype`). Strip the pointer so the subscription
                // name and serialized bytes describe the component,
                // not its address.
                const T = @TypeOf(comp);
                if (comptime @typeInfo(T) == .pointer) {
                    const name = @typeName(@typeInfo(T).pointer.child);
                    if (p.isComponentSubscribed(name)) {
                        p.emitComponentChanged(@intCast(entity), name, std.mem.asBytes(comp)) catch {};
                    }
                } else {
                    const name = @typeName(T);
                    if (p.isComponentSubscribed(name)) {
                        p.emitComponentChanged(@intCast(entity), name, std.mem.asBytes(&comp)) catch {};
                    }
                }
            }
        }

        pub fn getPosition(self: *Game, entity: Entity) Position {
            if (self.ecs_backend.getComponent(entity, Position)) |p| return p.*;
            return Position{};
        }

        pub fn getWorldPosition(self: *Game, entity: Entity) Position {
            return hierarchy.computeWorldPos(EcsImpl, Parent, self.ecs_backend, entity, 0);
        }

        pub fn setWorldPosition(self: *Game, entity: Entity, world_pos: Position) void {
            if (self.ecs_backend.getComponent(entity, Parent)) |parent_comp| {
                const parent_world = hierarchy.computeWorldPos(EcsImpl, Parent, self.ecs_backend, parent_comp.entity, 0);
                setPosition(self, entity, .{ .x = world_pos.x - parent_world.x, .y = world_pos.y - parent_world.y });
            } else {
                setPosition(self, entity, world_pos);
            }
        }

        pub fn setParent(self: *Game, child: Entity, parent_entity: Entity, opts: struct {
            inherit_rotation: bool = false,
            inherit_scale: bool = false,
        }) void {
            self.assertEntityAlive(child, "setParent (child)");
            self.assertEntityAlive(parent_entity, "setParent (parent)");
            if (hierarchy.wouldCreateCycle(EcsImpl, Parent, self.ecs_backend, child, parent_entity)) return;

            if (self.ecs_backend.getComponent(child, Parent)) |old_parent_comp| {
                if (self.ecs_backend.getComponent(old_parent_comp.entity, Children)) |old_children| {
                    old_children.removeChild(child);
                }
            }

            self.ecs_backend.addComponent(child, Parent{
                .entity = parent_entity,
                .inherit_rotation = opts.inherit_rotation,
                .inherit_scale = opts.inherit_scale,
            });

            if (self.ecs_backend.getComponent(parent_entity, Children)) |children_comp| {
                children_comp.addChild(child);
            } else {
                var new_children = Children{};
                new_children.addChild(child);
                self.ecs_backend.addComponent(parent_entity, new_children);
            }

            self.renderer.updateHierarchyFlag(child, true);
            self.renderer.markPositionDirty(child);
        }

        pub fn setParentKeepTransform(self: *Game, child: Entity, parent_entity: Entity, opts: struct {
            inherit_rotation: bool = false,
            inherit_scale: bool = false,
        }) void {
            const world_pos = getWorldPosition(self, child);
            setParent(self, child, parent_entity, opts);
            setWorldPosition(self, child, world_pos);
        }

        pub fn removeParent(self: *Game, child: Entity) void {
            self.assertEntityAlive(child, "removeParent");
            if (self.ecs_backend.getComponent(child, Parent)) |parent_comp| {
                if (self.ecs_backend.getComponent(parent_comp.entity, Children)) |children_comp| {
                    children_comp.removeChild(child);
                }
            }
            self.ecs_backend.removeComponent(child, Parent);
            self.renderer.updateHierarchyFlag(child, false);
            self.renderer.markPositionDirty(child);
        }

        pub fn removeParentKeepTransform(self: *Game, child: Entity) void {
            const world_pos = getWorldPosition(self, child);
            removeParent(self, child);
            setPosition(self, child, world_pos);
        }

        pub fn getParent(self: *Game, entity: Entity) ?Entity {
            if (self.ecs_backend.getComponent(entity, Parent)) |p| return p.entity;
            return null;
        }

        pub fn getChildren(self: *Game, entity: Entity) []const Entity {
            if (self.ecs_backend.getComponent(entity, Children)) |c| return c.getChildren();
            return &.{};
        }

        pub fn hasChildren(self: *Game, entity: Entity) bool {
            if (self.ecs_backend.getComponent(entity, Children)) |c| return c.count() > 0;
            return false;
        }

        pub fn isRoot(self: *Game, entity: Entity) bool {
            return !self.ecs_backend.hasComponent(entity, Parent);
        }

        // ── Generic Component Access ──────────────────────────────

        pub fn addComponent(self: *Game, entity: Entity, component: anytype) void {
            self.ecs_backend.addComponent(entity, component);
            const T = @TypeOf(component);
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onAdd")) {
                T.onAdd(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
            notifyComponentChanged(self, entity, component);
        }

        pub fn setComponent(self: *Game, entity: Entity, component: anytype) void {
            const T = @TypeOf(component);
            const is_update = self.ecs_backend.hasComponent(entity, T);
            self.ecs_backend.addComponent(entity, component);
            if (@typeInfo(T) == .@"struct") {
                if (is_update and @hasDecl(T, "onSet")) {
                    T.onSet(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
                } else if (!is_update and @hasDecl(T, "onAdd")) {
                    T.onAdd(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
                }
            }
            notifyComponentChanged(self, entity, component);
        }

        pub fn getComponent(self: *Game, entity: Entity, comptime T: type) ?*T {
            return self.ecs_backend.getComponent(entity, T);
        }

        /// Writes a single field of component `T` on `entity` in place.
        ///
        /// Silently no-ops when the entity does not have a component
        /// of type `T` — same semantics as `getComponent` returning
        /// `null`. This matches the flow-codegen runtime contract:
        /// generated `OnUpdate` flows that touch a missing component
        /// should not crash the game loop.
        ///
        /// The `comptime field: std.meta.FieldEnum(T)` selector keeps
        /// the call site type-checked end-to-end. The flow-codegen
        /// emits `game.setField(Position, .x, entity, value)`.
        ///
        /// Preview telemetry is fired after the mutation through the
        /// same `notifyComponentChanged` path used by `setComponent`,
        /// so the editor sees an updated component frame when it has
        /// subscribed to `T`. For `Position` specifically the renderer's
        /// dirty-tracking is also poked (mirroring `setPosition`) so
        /// a flow that nudges `Position.x` doesn't drift the on-screen
        /// sprite out of sync with the ECS state.
        pub fn setField(
            self: *Game,
            comptime T: type,
            comptime field: std.meta.FieldEnum(T),
            entity: Entity,
            value: @FieldType(T, @tagName(field)),
        ) void {
            const comp_ptr = self.ecs_backend.getComponent(entity, T) orelse return;
            @field(comp_ptr.*, @tagName(field)) = value;
            if (T == Position) {
                self.renderer.markPositionDirtyWithChildren(EcsImpl, self.ecs_backend, entity);
            }
            notifyComponentChanged(self, entity, comp_ptr);
        }

        pub fn hasComponent(self: *Game, entity: Entity, comptime T: type) bool {
            return self.ecs_backend.hasComponent(entity, T);
        }

        pub fn removeComponent(self: *Game, entity: Entity, comptime T: type) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onRemove")) {
                T.onRemove(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
            self.ecs_backend.removeComponent(entity, T);
        }

        /// Fire onReady for a component type on a given entity.
        /// Called by the scene loader after ALL components have been added,
        /// so onReady callbacks can safely access sibling components.
        pub fn fireOnReady(self: *Game, entity: Entity, comptime T: type) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "onReady")) {
                T.onReady(ComponentPayload{ .entity_id = @intCast(entity), .game_ptr = @ptrCast(self) });
            }
        }
    };
}
