const std = @import("std");
const engine = @import("engine");
const core = @import("labelle-core");

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

test "font value types are the canonical labelle-core types" {
    // The point of #647 is *nominal* identity, not just matching layout: the
    // size test above would still pass if engine reintroduced a structurally-
    // identical-but-distinct `extern struct`. Lock the alias so the assembler's
    // codegen-marshal `@ptrCast` stays a genuine identity cast.
    try std.testing.expect(engine.Glyph == core.Glyph);
    try std.testing.expect(engine.CodepointEntry == core.CodepointEntry);
    try std.testing.expect(engine.KernPair == core.KernPair);
}
