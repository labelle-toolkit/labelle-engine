/// Gizmo mixin — debug drawing, entity selection, gizmo rendering.
const std = @import("std");
const gizmo_draws_mod = @import("gizmo_draws.zig");

/// Returns the gizmo mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const GizmoDraw = gizmo_draws_mod.GizmoDraw;

    return struct {
        pub fn setGizmosEnabled(self: *Game, enabled: bool) void {
            self.gizmos_enabled = enabled;
        }

        pub fn isGizmosEnabled(self: *const Game) bool {
            return self.gizmos_enabled;
        }

        // World-space gizmos

        pub fn drawGizmoLine(self: *Game, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawLine(self.allocator, x1, y1, x2, y2, color);
        }

        pub fn drawGizmoRect(self: *Game, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            self.gizmo_state.drawRect(self.allocator, x, y, w, h, color);
        }

        pub fn drawGizmoCircle(self: *Game, x: f32, y: f32, radius: f32, color: u32) void {
            self.gizmo_state.drawCircle(self.allocator, x, y, radius, color);
        }

        pub fn drawGizmoArrow(self: *Game, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawArrow(self.allocator, x1, y1, x2, y2, color);
        }

        // Category-aware world-space gizmos

        pub fn drawGizmoLineCategory(self: *Game, category: u8, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawLineWithCategory(self.allocator, category, x1, y1, x2, y2, color);
        }

        pub fn drawGizmoRectCategory(self: *Game, category: u8, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            self.gizmo_state.drawRectWithCategory(self.allocator, category, x, y, w, h, color);
        }

        pub fn drawGizmoCircleCategory(self: *Game, category: u8, x: f32, y: f32, radius: f32, color: u32) void {
            self.gizmo_state.drawCircleWithCategory(self.allocator, category, x, y, radius, color);
        }

        pub fn drawGizmoArrowCategory(self: *Game, category: u8, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawArrowWithCategory(self.allocator, category, x1, y1, x2, y2, color);
        }

        // Screen-space gizmos

        pub fn drawGizmoLineScreen(self: *Game, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawLineScreen(self.allocator, x1, y1, x2, y2, color);
        }

        pub fn drawGizmoRectScreen(self: *Game, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            self.gizmo_state.drawRectScreen(self.allocator, x, y, w, h, color);
        }

        pub fn drawGizmoCircleScreen(self: *Game, x: f32, y: f32, radius: f32, color: u32) void {
            self.gizmo_state.drawCircleScreen(self.allocator, x, y, radius, color);
        }

        pub fn drawGizmoArrowScreen(self: *Game, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.gizmo_state.drawArrowScreen(self.allocator, x1, y1, x2, y2, color);
        }

        pub fn clearGizmos(self: *Game) void {
            self.gizmo_state.clear();
        }

        pub fn clearGizmoGroup(self: *Game, group: []const u8) void {
            self.gizmo_state.clearGroup(group);
        }

        pub fn getGizmoDraws(self: *const Game) []const GizmoDraw {
            return self.gizmo_state.getDraws();
        }

        // Gizmo categories

        pub fn setGizmoCategory(self: *Game, category: u8, enabled: bool) void {
            self.gizmo_state.setCategoryEnabled(category, enabled);
        }

        pub fn isGizmoCategoryEnabled(self: *const Game, category: u8) bool {
            return self.gizmo_state.isCategoryEnabled(category);
        }

        // Entity selection for debug

        pub fn selectEntity(self: *Game, entity: Entity) void {
            self.gizmo_state.select(entity);
        }

        pub fn deselectEntity(self: *Game, entity: Entity) void {
            self.gizmo_state.deselect(entity);
        }

        pub fn isEntitySelected(self: *const Game, entity: Entity) bool {
            return self.gizmo_state.isSelected(entity);
        }

        pub fn clearSelection(self: *Game) void {
            self.gizmo_state.clearSelection();
        }

        /// Render all collected gizmo draws via the renderer.
        /// Passes all draws — the category check happens at draw time in the
        /// gizmo_state (category-aware methods skip appending disabled draws).
        /// Category 0 (uncategorized) draws are always included.
        pub fn renderGizmos(self: *Game) void {
            if (!self.gizmos_enabled) return;
            const draws = self.gizmo_state.getDraws();
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "renderGizmoDraws")) {
                self.renderer.renderGizmoDraws(draws);
            }
        }
    };
}
