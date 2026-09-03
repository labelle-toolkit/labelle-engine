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

        /// Draw a debug string at world (x, y) — an entity id, a solver's step
        /// count, an FPS readout. Routes to `GizmoDraw.Kind.text`, which
        /// labelle-core already defines.
        ///
        /// **String lifetime**: `text` is COPIED into a per-frame byte arena
        /// owned by the game's gizmo state, so the caller's buffer may be
        /// reused or freed the instant this returns (a `bufPrint` stack buffer
        /// is fine). The copy — like the draw itself — lives until the next
        /// `clearGizmos()`, and `getGizmoText()` slices point into that arena,
        /// so they are invalidated by `clearGizmos()` or by a later
        /// `drawGizmoText*` call that grows the arena.
        ///
        /// **Reaching the string**: `GizmoDraw` (labelle-core) has no text
        /// payload field, so the string is NOT on the draw. Resolve it by index
        /// over `getGizmoDraws()` with `getGizmoText(i)`. A backend reached
        /// through `renderGizmoDraws` therefore sees a positioned, coloured
        /// `.text` draw with no characters and skips it — the same no-op it
        /// already performs today. Painting it needs a `text: []const u8` field
        /// on core's `GizmoDraw`; see #827.
        pub fn drawGizmoText(self: *Game, x: f32, y: f32, text: []const u8, color: u32) void {
            self.gizmo_state.drawText(self.allocator, x, y, text, color);
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

        /// Category-gated `drawGizmoText`. Same string lifetime; nothing is
        /// appended (and nothing is copied) when `category` is disabled.
        pub fn drawGizmoTextCategory(self: *Game, category: u8, x: f32, y: f32, text: []const u8, color: u32) void {
            self.gizmo_state.drawTextWithCategory(self.allocator, category, x, y, text, color);
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

        /// Screen-space `drawGizmoText` — the HUD variant, and the one a debug
        /// readout usually wants. Same string lifetime.
        pub fn drawGizmoTextScreen(self: *Game, x: f32, y: f32, text: []const u8, color: u32) void {
            self.gizmo_state.drawTextScreen(self.allocator, x, y, text, color);
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

        /// The string of the `.text` draw at `draw_index` in `getGizmoDraws()`,
        /// or `null` for any other kind. Valid until the next `clearGizmos()`
        /// or `drawGizmoText*` call — see `drawGizmoText`.
        pub fn getGizmoText(self: *const Game, draw_index: usize) ?[]const u8 {
            return self.gizmo_state.getText(draw_index);
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
