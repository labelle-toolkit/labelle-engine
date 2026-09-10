const std = @import("std");
const a = @import("animation");
const t = std.testing;
const clip = a.Clip{ .name = "walk", .frames = &.{ "a", "b", "c" }, .markers = &.{
    .{ .name = "start", .frame = 0 },
    .{ .name = "second", .frame = 1 },
    .{ .name = "same_frame", .frame = 1 },
    .{ .name = "last", .frame = 2 },
} };
const Sink = struct {
    items: std.ArrayList(a.Occurrence) = .empty,
    fail_at: ?usize = null,
    pub fn emit(self: *@This(), event: a.Occurrence) !void {
        if (self.fail_at == self.items.items.len) return error.OutOfMemory;
        try self.items.append(t.allocator, event);
    }
    fn deinit(self: *@This()) void {
        self.items.deinit(t.allocator);
    }
};

test "named JSONC markers own source and preserve author order" {
    const input = try t.allocator.dupe(u8,
        \\{"version":1,"clips":{"x":{"frames":["a","b"],"markers":[{"name":"later","frame":1},{"name":"first","frame":0}]}}}
    );
    var def = try a.Definition.parse(t.allocator, input);
    t.allocator.free(input);
    defer def.deinit();
    try t.expectEqualStrings("later", def.clips[0].markers[0].name);
    try t.expectEqual(@as(u8, 0), def.clips[0].markers[1].frame);
}

test "invalid marker metadata fails at definition load" {
    inline for (.{
        .{ error.InvalidMarkerName, "[{\"name\":\"\",\"frame\":0}]" },
        .{ error.InvalidMarkerFrame, "[{\"name\":\"x\",\"frame\":1}]" },
        .{ error.InvalidMarkerFrame, "[{\"name\":\"x\",\"frame\":-1}]" },
        .{ error.DuplicateMarker, "[{\"name\":\"x\",\"frame\":0},{\"name\":\"x\",\"frame\":0}]" },
        .{ error.UnknownField, "[{\"name\":\"x\",\"frame\":0,\"extra\":1}]" },
    }) |case| try t.expectError(case[0], a.Definition.parse(t.allocator, "{\"version\":1,\"clips\":{\"x\":{\"frames\":[\"a\"],\"markers\":" ++ case[1] ++ "}}}"));
}

test "large multi-loop batch matches tiny pumps exactly and never drops occurrences" {
    var whole: a.MarkerCursor = .{};
    var bounded: a.MarkerCursor = .{};
    var expected: Sink = .{};
    defer expected.deinit();
    var actual: Sink = .{};
    defer actual.deinit();
    try whole.offer(2000, 1);
    try bounded.offer(2000, 1);
    _ = try whole.pump(&clip, .loop, .{ .frames = 3000, .events = 5000 }, &expected);
    while ((try bounded.pump(&clip, .loop, .{ .frames = 2, .events = 1 }, &actual)).pending) {}
    try t.expectEqualSlices(a.Occurrence, expected.items.items, actual.items.items);
    try t.expect(actual.items.items.len > 2500);
    try t.expectEqual(whole.frame, bounded.frame);
    try t.expectEqual(whole.repetition, bounded.repetition);
}

test "failed enqueue retries exactly one occurrence without advancing beyond it" {
    var cursor: a.MarkerCursor = .{};
    var sink = Sink{ .fail_at = 2 };
    defer sink.deinit();
    try cursor.offer(5, 1);
    try t.expectError(error.OutOfMemory, cursor.pump(&clip, .loop, .{}, &sink));
    try t.expectEqual(@as(u8, 1), cursor.frame);
    try t.expectEqual(@as(u64, 2), cursor.sequence);
    try t.expectError(error.Busy, cursor.offer(1, 1));
    sink.fail_at = null;
    _ = try cursor.pump(&clip, .loop, .{}, &sink);
    for (sink.items.items, 0..) |event, i| try t.expectEqual(@as(u64, @intCast(i)), event.sequence);
    try t.expectEqual(@as(u16, 2), sink.items.items[2].marker_index);
}

test "once final marker precedes one completion and pause does not replay start" {
    var cursor: a.MarkerCursor = .{};
    var sink: Sink = .{};
    defer sink.deinit();
    try cursor.offer(0, 2);
    _ = try cursor.pump(&clip, .once, .{}, &sink);
    try cursor.offer(0, 2);
    _ = try cursor.pump(&clip, .once, .{}, &sink);
    try t.expectEqual(@as(usize, 1), sink.items.items.len);
    try cursor.offer(5, 2);
    _ = try cursor.pump(&clip, .once, .{}, &sink);
    try t.expectEqual(@as(usize, 5), sink.items.items.len);
    try t.expectEqual(.marker, sink.items.items[3].kind);
    try t.expectEqual(.complete, sink.items.items[4].kind);
    try cursor.offer(10, 2);
    _ = try cursor.pump(&clip, .once, .{}, &sink);
    try t.expectEqual(@as(usize, 5), sink.items.items.len);
}

test "ping pong enters endpoints once and reverse loop wraps correctly" {
    var cursor: a.MarkerCursor = .{};
    var sink: Sink = .{};
    defer sink.deinit();
    try cursor.offer(4, 1);
    _ = try cursor.pump(&clip, .ping_pong, .{}, &sink);
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(t.allocator);
    for (sink.items.items) |e| if (e.kind == .marker) {
        try frames.append(t.allocator, e.frame);
    };
    try t.expectEqualSlices(u8, &.{ 0, 1, 1, 2, 1, 1, 0 }, frames.items);
    cursor = .{ .frame = 2, .forward = false };
    sink.items.clearRetainingCapacity();
    try cursor.offer(3, 1);
    _ = try cursor.pump(&clip, .loop, .{}, &sink);
    try t.expectEqual(@as(u8, 2), cursor.frame);
    try t.expectEqual(@as(u64, 1), cursor.repetition);
}

test "invalid and excessive time does not mutate the cursor" {
    var cursor: a.MarkerCursor = .{};
    try t.expectError(error.InvalidTime, cursor.offer(std.math.inf(f64), 1));
    try t.expectError(error.InvalidTime, cursor.offer(-1, 1));
    try t.expectError(error.TimeOverflow, cursor.offer(4294967296, 1));
    try t.expectEqual(@as(u64, 0), cursor.steps);
    try t.expectEqual(@as(f64, 0), cursor.fraction);
}

fn markerAllocationProbe(allocator: std.mem.Allocator) !void {
    var def = try a.Definition.parse(allocator, "{\"version\":1,\"clips\":{\"x\":{\"frames\":[\"a\"],\"markers\":[{\"name\":\"cue\",\"frame\":0}]}}}");
    defer def.deinit();
}

test "marker definition allocation failures release the arena" {
    try t.checkAllAllocationFailures(t.allocator, markerAllocationProbe, .{});
}

test "zero frame budget can deliver entered cues but never advances queued beats" {
    var cursor: a.MarkerCursor = .{};
    var sink: Sink = .{};
    defer sink.deinit();
    try cursor.offer(10, 1);
    const paused = try cursor.pump(&clip, .loop, .{ .frames = 0 }, &sink);
    try t.expect(paused.pending);
    try t.expectEqual(@as(u8, 0), cursor.frame);
    try t.expectEqual(@as(u64, 10), cursor.steps);
    try t.expectEqual(@as(usize, 1), sink.items.items.len);
    _ = try cursor.pump(&clip, .loop, .{}, &sink);
    try t.expectEqual(@as(u8, 1), cursor.frame);
}
