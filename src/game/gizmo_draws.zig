/// Standalone gizmo draws — ephemeral debug drawings and entity selection.
const std = @import("std");
const core = @import("labelle-core");

pub const GizmoDraw = core.GizmoDraw;

/// Max gizmo categories supported.
pub const MAX_GIZMO_CATEGORIES: usize = 32;

/// Joins one `.text` gizmo to its string inside the frame's byte arena.
///
/// `GizmoDraw` is labelle-core's type and carries no text payload
/// (`kind, x1, y1, x2, y2, color, group, space, category`), so a text gizmo's
/// characters cannot live on the draw itself. They live in `GizmoState`'s
/// `text_bytes` arena instead, and this span records which draw they belong to
/// — by index into `draws`, not by pointer, so the arena is free to reallocate
/// as it grows. Both are reset together by `clear()`.
pub const GizmoTextSpan = struct {
    /// Index into `GizmoState.draws` of the `.text` draw this string is for.
    draw_index: u32,
    /// Byte offset into `GizmoState.text_bytes`.
    start: u32,
    /// Byte length of the string.
    len: u32,
};

pub fn GizmoState(comptime Entity: type) type {
    return struct {
        const Self = @This();

        draws: std.ArrayListUnmanaged(GizmoDraw) = .empty,
        /// Per-frame byte arena holding every `.text` gizmo's characters.
        /// Strings are COPIED in at draw time and stay valid until `clear()`
        /// (the frame's `clearGizmos`), so a caller may reuse or free its own
        /// buffer the moment the draw call returns.
        text_bytes: std.ArrayListUnmanaged(u8) = .empty,
        /// One entry per live `.text` draw, joining it to its bytes.
        text_spans: std.ArrayListUnmanaged(GizmoTextSpan) = .empty,
        selected: std.AutoHashMap(Entity, void),
        /// Per-category enable/disable. Index 0 = "all" (always enabled by default).
        category_enabled: [MAX_GIZMO_CATEGORIES]bool = [_]bool{true} ** MAX_GIZMO_CATEGORIES,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .selected = std.AutoHashMap(Entity, void).init(allocator) };
        }

        pub fn setCategoryEnabled(self: *Self, category: u8, enabled: bool) void {
            if (category < MAX_GIZMO_CATEGORIES) {
                self.category_enabled[category] = enabled;
            }
        }

        pub fn isCategoryEnabled(self: *const Self, category: u8) bool {
            if (category >= MAX_GIZMO_CATEGORIES) return false;
            return self.category_enabled[category];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.draws.deinit(allocator);
            self.text_bytes.deinit(allocator);
            self.text_spans.deinit(allocator);
            self.selected.deinit();
        }

        // ── Standalone Draws ─────────────────────────────────────

        pub fn drawLine(self: *Self, allocator: std.mem.Allocator, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .line, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color }) catch {};
        }

        pub fn drawRect(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .rect, .x1 = x, .y1 = y, .x2 = w, .y2 = h, .color = color }) catch {};
        }

        pub fn drawCircle(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, radius: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .circle, .x1 = x, .y1 = y, .x2 = radius, .color = color }) catch {};
        }

        pub fn drawArrow(self: *Self, allocator: std.mem.Allocator, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .arrow, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color }) catch {};
        }

        /// Append a `.text` draw at (x, y). `text` is copied into `text_bytes`
        /// and is valid until `clear()`.
        pub fn drawText(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, text: []const u8, color: u32) void {
            self.appendText(allocator, .{ .kind = .text, .x1 = x, .y1 = y, .color = color }, text);
        }

        // Category-aware variants

        pub fn drawLineWithCategory(self: *Self, allocator: std.mem.Allocator, cat: u8, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            if (cat >= MAX_GIZMO_CATEGORIES or !self.category_enabled[cat]) return;
            self.draws.append(allocator, .{ .kind = .line, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .category = cat }) catch {};
        }

        pub fn drawArrowWithCategory(self: *Self, allocator: std.mem.Allocator, cat: u8, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            if (cat >= MAX_GIZMO_CATEGORIES or !self.category_enabled[cat]) return;
            self.draws.append(allocator, .{ .kind = .arrow, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .category = cat }) catch {};
        }

        pub fn drawRectWithCategory(self: *Self, allocator: std.mem.Allocator, cat: u8, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            if (cat >= MAX_GIZMO_CATEGORIES or !self.category_enabled[cat]) return;
            self.draws.append(allocator, .{ .kind = .rect, .x1 = x, .y1 = y, .x2 = w, .y2 = h, .color = color, .category = cat }) catch {};
        }

        pub fn drawCircleWithCategory(self: *Self, allocator: std.mem.Allocator, cat: u8, x: f32, y: f32, radius: f32, color: u32) void {
            if (cat >= MAX_GIZMO_CATEGORIES or !self.category_enabled[cat]) return;
            self.draws.append(allocator, .{ .kind = .circle, .x1 = x, .y1 = y, .x2 = radius, .color = color, .category = cat }) catch {};
        }

        pub fn drawTextWithCategory(self: *Self, allocator: std.mem.Allocator, cat: u8, x: f32, y: f32, text: []const u8, color: u32) void {
            if (cat >= MAX_GIZMO_CATEGORIES or !self.category_enabled[cat]) return;
            self.appendText(allocator, .{ .kind = .text, .x1 = x, .y1 = y, .color = color, .category = cat }, text);
        }

        // Screen-space variants (for HUD overlays, debug text, etc.)

        pub fn drawLineScreen(self: *Self, allocator: std.mem.Allocator, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .line, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .space = .screen }) catch {};
        }

        pub fn drawRectScreen(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .rect, .x1 = x, .y1 = y, .x2 = w, .y2 = h, .color = color, .space = .screen }) catch {};
        }

        pub fn drawCircleScreen(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, radius: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .circle, .x1 = x, .y1 = y, .x2 = radius, .color = color, .space = .screen }) catch {};
        }

        pub fn drawArrowScreen(self: *Self, allocator: std.mem.Allocator, x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            self.draws.append(allocator, .{ .kind = .arrow, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .space = .screen }) catch {};
        }

        pub fn drawTextScreen(self: *Self, allocator: std.mem.Allocator, x: f32, y: f32, text: []const u8, color: u32) void {
            self.appendText(allocator, .{ .kind = .text, .x1 = x, .y1 = y, .color = color, .space = .screen }, text);
        }

        // ── Text Payloads ────────────────────────────────────────

        /// Append `draw` (always `kind == .text`) together with a copy of its
        /// string. All-or-nothing: if either the bytes, the draw or the span
        /// fails to allocate, everything is rolled back so `draws` never holds
        /// a `.text` entry whose string cannot be resolved.
        fn appendText(self: *Self, allocator: std.mem.Allocator, draw: GizmoDraw, text: []const u8) void {
            const start = self.text_bytes.items.len;
            self.text_bytes.appendSlice(allocator, text) catch return;
            self.draws.append(allocator, draw) catch {
                self.text_bytes.shrinkRetainingCapacity(start);
                return;
            };
            self.text_spans.append(allocator, .{
                .draw_index = @intCast(self.draws.items.len - 1),
                .start = @intCast(start),
                .len = @intCast(text.len),
            }) catch {
                _ = self.draws.pop();
                self.text_bytes.shrinkRetainingCapacity(start);
            };
        }

        /// The string of the `.text` draw at `draw_index` in `getDraws()`, or
        /// `null` for any other kind. The slice points into the frame arena and
        /// is invalidated by the next `clear()` or `drawText*` call.
        ///
        /// This index join is what stands in for the `text: []const u8` field
        /// `GizmoDraw` does not have — see `GizmoTextSpan`.
        pub fn getText(self: *const Self, draw_index: usize) ?[]const u8 {
            for (self.text_spans.items) |span| {
                if (span.draw_index == draw_index) {
                    return self.text_bytes.items[span.start .. span.start + span.len];
                }
            }
            return null;
        }

        pub fn clear(self: *Self) void {
            self.draws.clearRetainingCapacity();
            self.text_bytes.clearRetainingCapacity();
            self.text_spans.clearRetainingCapacity();
        }

        pub fn clearGroup(self: *Self, group: []const u8) void {
            var i: usize = 0;
            while (i < self.draws.items.len) {
                if (std.mem.eql(u8, self.draws.items[i].group, group)) {
                    _ = self.draws.orderedRemove(i);
                    self.dropTextSpan(i);
                } else {
                    i += 1;
                }
            }
        }

        /// Re-join `text_spans` to `draws` after `orderedRemove(removed_index)`:
        /// drop the removed draw's span and shift every later `draw_index` down
        /// by one. The orphaned bytes stay in `text_bytes` until `clear()` —
        /// it is a frame arena, not a heap, so nothing is compacted mid-frame.
        fn dropTextSpan(self: *Self, removed_index: usize) void {
            var i: usize = 0;
            while (i < self.text_spans.items.len) {
                const span = &self.text_spans.items[i];
                if (span.draw_index == removed_index) {
                    _ = self.text_spans.orderedRemove(i);
                    continue;
                }
                if (span.draw_index > removed_index) span.draw_index -= 1;
                i += 1;
            }
        }

        pub fn getDraws(self: *const Self) []const GizmoDraw {
            return self.draws.items;
        }

        // ── Entity Selection ─────────────────────────────────────

        pub fn select(self: *Self, entity: Entity) void {
            self.selected.put(entity, {}) catch {};
        }

        pub fn deselect(self: *Self, entity: Entity) void {
            _ = self.selected.remove(entity);
        }

        pub fn isSelected(self: *const Self, entity: Entity) bool {
            return self.selected.contains(entity);
        }

        pub fn clearSelection(self: *Self) void {
            self.selected.clearRetainingCapacity();
        }
    };
}
