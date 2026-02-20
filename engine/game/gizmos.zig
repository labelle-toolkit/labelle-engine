// Gizmos — debug visualizations, entity selection, standalone drawing.
//
// This is a zero-bit field mixin for GameWith(Hooks). Methods access the parent
// Game struct via @fieldParentPtr("gizmos", self).

const std = @import("std");
const labelle = @import("labelle");
const ecs = @import("ecs");
const render_pipeline_mod = @import("../../render/src/pipeline.zig");
const core_mod = @import("../../core/mod.zig");

const Entity = ecs.Entity;
const Sprite = render_pipeline_mod.Sprite;
const Shape = render_pipeline_mod.Shape;
const Text = render_pipeline_mod.Text;
const Icon = render_pipeline_mod.Icon;
const Color = render_pipeline_mod.Color;

const entityToU64 = core_mod.entityToU64;

pub fn GizmosMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        /// Shape primitive union type from labelle-gfx. Used for standalone gizmo drawing.
        pub const GizmoShape = labelle.retained_engine.Shape;

        /// Standalone gizmo that persists until cleared.
        pub const StandaloneGizmo = GameType.StandaloneGizmo;

        fn game(self: *Self) *GameType {
            return @alignCast(@fieldParentPtr("gizmos", self));
        }

        fn gameConst(self: *const Self) *const GameType {
            return @alignCast(@fieldParentPtr("gizmos", self));
        }

        /// Enable or disable gizmo rendering.
        /// Gizmos are debug-only visualizations that are stripped in release builds.
        /// When disabled, gizmo entities are hidden but not destroyed.
        pub fn setEnabled(self: *Self, enabled: bool) void {
            const g = self.game();
            if (g.gizmos_enabled == enabled) return;
            g.gizmos_enabled = enabled;
            self.updateGizmoVisibility();
        }

        /// Check if gizmos are currently enabled.
        pub fn areEnabled(self: *const Self) bool {
            return self.gameConst().gizmos_enabled;
        }

        // ── Entity Selection ──────────────────────────────────────

        /// Select an entity (for selected-only gizmo visibility).
        pub fn selectEntity(self: *Self, entity: Entity) void {
            const g = self.game();
            const idx = entityToU64(entity);
            if (idx < g.selected_entities.capacity()) {
                g.selected_entities.set(@intCast(idx));
                self.updateGizmoVisibility();
            }
        }

        /// Deselect an entity.
        pub fn deselectEntity(self: *Self, entity: Entity) void {
            const g = self.game();
            const idx = entityToU64(entity);
            if (idx < g.selected_entities.capacity()) {
                g.selected_entities.unset(@intCast(idx));
                self.updateGizmoVisibility();
            }
        }

        /// Clear all entity selections.
        pub fn clearSelection(self: *Self) void {
            const g = self.game();
            g.selected_entities.setRangeValue(.{ .start = 0, .end = g.selected_entities.capacity() }, false);
            self.updateGizmoVisibility();
        }

        /// Check if an entity is selected.
        pub fn isEntitySelected(self: *const Self, entity: Entity) bool {
            const g = self.gameConst();
            const idx = entityToU64(entity);
            if (idx >= g.selected_entities.capacity()) return false;
            return g.selected_entities.isSet(@intCast(idx));
        }

        /// Update visibility of all gizmos based on their visibility mode and selection state.
        pub fn updateGizmoVisibility(self: *Self) void {
            const g = self.game();
            const Gizmo = render_pipeline_mod.Gizmo;

            var view = g.registry.view(.{Gizmo});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                if (g.registry.getComponent(entity, Gizmo)) |gizmo| {
                    const should_show = switch (gizmo.visibility) {
                        .always => g.gizmos_enabled,
                        .selected_only => g.gizmos_enabled and
                            (gizmo.parent_entity != null and self.isEntitySelected(gizmo.parent_entity.?)),
                        .never => false,
                    };
                    self.setGizmoEntityVisible(g, entity, should_show);
                }
            }
        }

        /// Set visibility of a gizmo entity's visual components.
        fn setGizmoEntityVisible(_: *Self, g: *GameType, entity: Entity, visible: bool) void {
            var changed = false;
            const visual_components = .{ Sprite, Shape, Text, Icon };
            inline for (visual_components) |ComponentType| {
                if (g.registry.getComponent(entity, ComponentType)) |comp| {
                    if (comp.visible != visible) {
                        var updated = comp.*;
                        updated.visible = visible;
                        g.registry.set(entity, updated);
                        changed = true;
                    }
                }
            }
            if (changed) {
                g.pipeline.markVisualDirty(entity);
            }
        }

        // ── Standalone Gizmos ─────────────────────────────────────

        /// Draw a standalone gizmo (not bound to any entity).
        /// Gizmo persists until clearGizmos() is called.
        /// No-op in release builds or when gizmos are disabled.
        pub fn drawGizmo(self: *Self, shape: GizmoShape, x: f32, y: f32, color: Color) void {
            if (@import("builtin").mode != .Debug) return;
            const g = self.game();
            if (!g.gizmos_enabled) return;

            g.standalone_gizmos.append(g.allocator, .{
                .shape = shape,
                .x = x,
                .y = y,
                .color = color,
            }) catch return;
        }

        /// Draw an arrow gizmo from point (x1, y1) to point (x2, y2).
        pub fn drawArrow(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
            self.drawGizmo(.{ .arrow = .{
                .delta = .{ .x = x2 - x1, .y = y2 - y1 },
                .thickness = 2,
            } }, x1, y1, color);
        }

        /// Draw a ray gizmo from origin in direction for given length.
        pub fn drawRay(self: *Self, x: f32, y: f32, dir_x: f32, dir_y: f32, length: f32, color: Color) void {
            self.drawGizmo(.{ .ray = .{
                .direction = .{ .x = dir_x, .y = dir_y },
                .length = length,
                .thickness = 2,
            } }, x, y, color);
        }

        /// Draw a line gizmo from point (x1, y1) to point (x2, y2).
        pub fn drawLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
            self.drawGizmo(.{ .line = .{
                .end = .{ .x = x2 - x1, .y = y2 - y1 },
                .thickness = 2,
            } }, x1, y1, color);
        }

        /// Draw a circle gizmo at position with given radius.
        pub fn drawCircle(self: *Self, x: f32, y: f32, radius: f32, color: Color) void {
            self.drawGizmo(.{ .circle = .{ .radius = radius } }, x, y, color);
        }

        /// Draw a rectangle gizmo at position with given dimensions.
        pub fn drawRect(self: *Self, x: f32, y: f32, width: f32, height: f32, color: Color) void {
            self.drawGizmo(.{ .rectangle = .{
                .width = width,
                .height = height,
            } }, x, y, color);
        }

        /// Clear all standalone gizmos.
        pub fn clearGizmos(self: *Self) void {
            self.game().standalone_gizmos.clearRetainingCapacity();
        }

        /// Clear standalone gizmos in a specific group.
        pub fn clearGizmoGroup(self: *Self, group: []const u8) void {
            const g = self.game();
            var write_idx: usize = 0;
            for (g.standalone_gizmos.items) |item| {
                if (!std.mem.eql(u8, item.group, group)) {
                    g.standalone_gizmos.items[write_idx] = item;
                    write_idx += 1;
                }
            }
            g.standalone_gizmos.shrinkRetainingCapacity(write_idx);
        }

        /// Render standalone gizmos.
        /// No-op in release builds or when gizmos are disabled.
        pub fn renderStandaloneGizmos(self: *Self) void {
            if (@import("builtin").mode != .Debug) return;
            const g = self.game();
            if (!g.gizmos_enabled) return;

            const camera = g.retained_engine.cameras.getCamera();
            const screen_height = g.pipeline.screen_height;
            const zoom = camera.zoom;

            for (g.standalone_gizmos.items) |gizmo| {
                // Convert game Y-up to retained engine Y-down
                const world_x = gizmo.x;
                const world_y = screen_height - gizmo.y;

                // Convert world coords to screen pixels via camera
                const screen_pos = camera.worldToScreen(world_x, world_y);

                // Flip shape vectors for Y-up to Y-down, and scale by zoom
                const screen_shape = transformShapeForScreen(gizmo.shape, zoom);

                g.retained_engine.drawShapeScreen(screen_shape, .{ .x = screen_pos.x, .y = screen_pos.y }, gizmo.color);
            }
        }

        /// Transform shape vectors from game Y-up to screen Y-down,
        /// scaling relative vectors by camera zoom for correct screen-space rendering.
        fn transformShapeForScreen(shape: GizmoShape, zoom: f32) GizmoShape {
            return switch (shape) {
                .circle => |c| .{ .circle = .{
                    .radius = c.radius * zoom,
                    .fill = c.fill,
                    .thickness = c.thickness,
                } },
                .rectangle => |r| .{ .rectangle = .{
                    .width = r.width * zoom,
                    .height = r.height * zoom,
                    .fill = r.fill,
                    .thickness = r.thickness,
                } },
                .polygon => shape,
                .line => |l| .{ .line = .{
                    .end = .{ .x = l.end.x * zoom, .y = -l.end.y * zoom },
                    .thickness = l.thickness,
                } },
                .triangle => |t| .{ .triangle = .{
                    .p2 = .{ .x = t.p2.x * zoom, .y = -t.p2.y * zoom },
                    .p3 = .{ .x = t.p3.x * zoom, .y = -t.p3.y * zoom },
                    .fill = t.fill,
                } },
                .arrow => |a| .{ .arrow = .{
                    .delta = .{ .x = a.delta.x * zoom, .y = -a.delta.y * zoom },
                    .head_size = a.head_size * zoom,
                    .thickness = a.thickness,
                    .fill = a.fill,
                } },
                .ray => |r| .{ .ray = .{
                    .direction = .{ .x = r.direction.x, .y = -r.direction.y },
                    .length = r.length * zoom,
                    .thickness = r.thickness,
                } },
            };
        }
    };
}
