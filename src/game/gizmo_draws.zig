/// Standalone gizmo draws — ephemeral debug drawings and entity selection.
const std = @import("std");
const core = @import("labelle-core");

pub const GizmoDraw = core.GizmoDraw;

pub fn GizmoState(comptime Entity: type) type {
    return struct {
        const Self = @This();

        draws: std.ArrayListUnmanaged(GizmoDraw) = .{},
        selected: std.AutoHashMap(Entity, void),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .selected = std.AutoHashMap(Entity, void).init(allocator) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.draws.deinit(allocator);
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

        pub fn clear(self: *Self) void {
            self.draws.clearRetainingCapacity();
        }

        pub fn clearGroup(self: *Self, group: []const u8) void {
            var i: usize = 0;
            while (i < self.draws.items.len) {
                if (std.mem.eql(u8, self.draws.items[i].group, group)) {
                    _ = self.draws.orderedRemove(i);
                } else {
                    i += 1;
                }
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
