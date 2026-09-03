//! `drawGizmoText` + its `…Screen` / `…Category` variants on the Game gizmo
//! mixin (#827).
//!
//! The design point under test: labelle-core's `GizmoDraw` has no text payload
//! (`kind, x1, y1, x2, y2, color, group, space, category`), so the string
//! cannot ride on the draw. It is copied into a per-frame byte arena on the
//! game's gizmo state and joined to its draw by index — `getGizmoText(i)`.
//! These tests pin the two things that make contractual: the draw carries the
//! right geometry/kind/space/category, and the COPY outlives the caller's
//! buffer but not the frame's `clearGizmos()`.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");
const Game = engine.Game;

test "gizmo text: drawGizmoText appends a .text draw at the given position" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoText(12, 34, "entropy 7", 0xFFFF0000);

    const draws = game.getGizmoDraws();
    try testing.expectEqual(@as(usize, 1), draws.len);
    try testing.expectEqual(core.GizmoDraw.Kind.text, draws[0].kind);
    try testing.expectEqual(@as(f32, 12), draws[0].x1);
    try testing.expectEqual(@as(f32, 34), draws[0].y1);
    try testing.expectEqual(@as(u32, 0xFFFF0000), draws[0].color);
    try testing.expectEqual(core.GizmoDraw.Space.world, draws[0].space);
    try testing.expectEqualStrings("entropy 7", game.getGizmoText(0).?);
}

test "gizmo text: the string is copied, so a reused caller buffer is safe" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    var buf: [32]u8 = undefined;
    game.drawGizmoText(0, 0, try std.fmt.bufPrint(&buf, "fps {d}", .{60}), 0xFF00FF00);
    // Overwrite the caller's buffer — the arena copy must not follow it.
    @memset(&buf, 'x');

    try testing.expectEqualStrings("fps 60", game.getGizmoText(0).?);
}

/// An allocator that never grows in place and scribbles `0xAA` over every
/// block it frees. Any `ArrayList` growth therefore MOVES the buffer and
/// poisons the old one, so a copy whose source still points into the pre-growth
/// buffer reads garbage instead of quietly surviving on stale-but-intact heap.
const MovingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *MovingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MovingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MovingAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "gizmo text: a getGizmoText slice fed back in survives the arena moving" {
    var moving = MovingAllocator{ .child = testing.allocator };
    var game = Game.init(moving.allocator());
    defer game.deinit();

    game.drawGizmoText(0, 0, "aliased", 0xFF00FF00);

    // Each round hands the previous draw's arena slice straight back to
    // `drawGizmoText`, so the copy's source lives in the very buffer the append
    // has to grow — and this allocator guarantees that the growth relocates and
    // poisons that source. 40 rounds because `ArrayList`'s initial capacity for
    // `u8` is a cache line (64 B): fewer rounds never reallocate at all.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        game.drawGizmoText(0, 0, game.getGizmoText(i).?, 0xFF00FF00);
    }

    var j: usize = 0;
    while (j <= 40) : (j += 1) {
        try testing.expectEqualStrings("aliased", game.getGizmoText(j).?);
    }
}

test "gizmo text: drawGizmoTextScreen marks the draw screen-space" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoTextScreen(4, 4, "hud", 0xFFFFFFFF);

    const draws = game.getGizmoDraws();
    try testing.expectEqual(@as(usize, 1), draws.len);
    try testing.expectEqual(core.GizmoDraw.Space.screen, draws[0].space);
    try testing.expectEqualStrings("hud", game.getGizmoText(0).?);
}

test "gizmo text: drawGizmoTextCategory tags the draw and honours the gate" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoTextCategory(3, 1, 2, "solver", 0xFF0000FF);
    try testing.expectEqual(@as(usize, 1), game.getGizmoDraws().len);
    try testing.expectEqual(@as(u8, 3), game.getGizmoDraws()[0].category);
    try testing.expectEqualStrings("solver", game.getGizmoText(0).?);

    // A disabled category appends nothing at all.
    game.setGizmoCategory(3, false);
    game.drawGizmoTextCategory(3, 9, 9, "dropped", 0xFF0000FF);
    try testing.expectEqual(@as(usize, 1), game.getGizmoDraws().len);
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(1));
}

test "gizmo text: getGizmoText is null for non-text kinds and out-of-range" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoLine(0, 0, 1, 1, 0xFF00FF00);
    game.drawGizmoText(0, 0, "label", 0xFF00FF00);
    game.drawGizmoCircle(5, 5, 2, 0xFF00FF00);

    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(0));
    try testing.expectEqualStrings("label", game.getGizmoText(1).?);
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(2));
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(99));
}

test "gizmo text: several texts stay joined to their own draws" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoText(0, 0, "alpha", 0xFF00FF00);
    game.drawGizmoRect(0, 0, 4, 4, 0xFF00FF00);
    game.drawGizmoTextScreen(1, 1, "beta", 0xFF00FF00);
    game.drawGizmoText(2, 2, "gamma", 0xFF00FF00);

    try testing.expectEqualStrings("alpha", game.getGizmoText(0).?);
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(1));
    try testing.expectEqualStrings("beta", game.getGizmoText(2).?);
    try testing.expectEqualStrings("gamma", game.getGizmoText(3).?);
}

test "gizmo text: clearGizmos resets the arena and the frame reuses it" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoText(0, 0, "frame one", 0xFF00FF00);
    try testing.expectEqualStrings("frame one", game.getGizmoText(0).?);

    game.clearGizmos();
    try testing.expectEqual(@as(usize, 0), game.getGizmoDraws().len);
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(0));

    // Next frame: the arena is reused from zero, indices start over.
    game.drawGizmoText(0, 0, "frame two", 0xFF00FF00);
    try testing.expectEqual(@as(usize, 1), game.getGizmoDraws().len);
    try testing.expectEqualStrings("frame two", game.getGizmoText(0).?);
}

test "gizmo text: clearGizmoGroup keeps the surviving text joined to its draw" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // No mixin call sets `group`, so every draw carries the default "" and
    // `clearGizmoGroup("")` removes the lot — the interesting case is that the
    // index join survives the ordered removals rather than dangling.
    game.drawGizmoText(0, 0, "alpha", 0xFF00FF00);
    game.drawGizmoText(1, 1, "beta", 0xFF00FF00);
    game.clearGizmoGroup("");

    try testing.expectEqual(@as(usize, 0), game.getGizmoDraws().len);
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(0));
    try testing.expectEqual(@as(?[]const u8, null), game.getGizmoText(1));
}

test "gizmo text: an empty string still produces a draw" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.drawGizmoText(3, 3, "", 0xFF00FF00);

    try testing.expectEqual(@as(usize, 1), game.getGizmoDraws().len);
    try testing.expectEqualStrings("", game.getGizmoText(0).?);
}

test "gizmo text: renderGizmos is a no-op for a renderer without drawText" {
    // The `@hasDecl` degradation the issue asks to preserve: the default Game's
    // renderer never sees a text payload and must not choke on a `.text` draw.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setGizmosEnabled(true);
    game.drawGizmoTextScreen(0, 0, "no backend font needed", 0xFF00FF00);
    game.renderGizmos();

    try testing.expectEqual(@as(usize, 1), game.getGizmoDraws().len);
}
