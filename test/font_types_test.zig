const std = @import("std");
const engine = @import("engine");

test "FontId.invalid fails isValid" {
    const id = engine.FontId.invalid;
    try std.testing.expect(!id.isValid());
}

test "FontId with non-zero generation is valid" {
    const id: engine.FontId = .{ .index = 0, .generation = 1 };
    try std.testing.expect(id.isValid());
}

test "Glyph / CodepointEntry / KernPair sizes are stable PODs" {
    // Lock the wire shape so the worker → main payload doesn't grow
    // accidental padding. If a field is added intentionally, update
    // this test alongside loader.zig's DecodedPayload.font.
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(engine.Glyph));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(engine.CodepointEntry));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(engine.KernPair));
}
