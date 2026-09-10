const std = @import("std");
const t = std.testing;
const Definition = @import("animation").Definition;

const source =
    \\{ // shared authoring asset
    \\ "version": 1,
    \\ "clips": {
    \\   "walk": {"frames_pattern":"walk_{frame:04}.png","from":1,"to":3},
    \\   "tiles": {"frames":["tiles/0","tiles/1"],},
    \\ },
    \\}
;

test "JSONC ranges and explicit extensionless frames own their source" {
    const buffer = try t.allocator.dupe(u8, source);
    var def = try Definition.parse(t.allocator, buffer);
    t.allocator.free(buffer);
    defer def.deinit();
    const walk = def.find("walk").?;
    try t.expectEqual(@as(usize, 3), walk.frames.len);
    try t.expectEqualStrings("walk_0001.png", walk.frames[0]);
    try t.expectEqualStrings("walk_0003.png", walk.frames[2]);
    try t.expectEqualStrings("tiles/0", def.find("tiles").?.frames[0]);
    try t.expect(def.find("absent") == null);
}

test "range supports u32 upper bound without overflow and does not truncate padding" {
    var def = try Definition.parse(t.allocator,
        \\{"version":1,"clips":{"x":{"frames_pattern":"tiles/{frame:02}","from":4294967295,"to":4294967295}}}
    );
    defer def.deinit();
    try t.expectEqualStrings("tiles/4294967295", def.clips[0].frames[0]);
}

test "malformed authoring fails explicitly" {
    const cases = .{
        .{ error.UnsupportedVersion, "{\"version\":2,\"clips\":{}}" },
        .{ error.EmptyClips, "{\"version\":1,\"clips\":{}}" },
        .{ error.UnknownField, "{\"version\":1,\"triggers\":[],\"clips\":{}}" },
        .{ error.DuplicateField, "{\"version\":1,\"version\":1,\"clips\":{}}" },
        .{ error.TrailingData, source ++ " false" },
    };
    inline for (cases) |case| try t.expectError(case[0], Definition.parse(t.allocator, case[1]));
    const clips = .{
        .{ error.ReversedRange, "{\"frames_pattern\":\"{frame}\",\"from\":3,\"to\":1}" },
        .{ error.TooManyFrames, "{\"frames_pattern\":\"{frame}\",\"from\":0,\"to\":255}" },
        .{ error.InvalidPattern, "{\"frames_pattern\":\"{frame:099}\",\"from\":0,\"to\":1}" },
        .{ error.InvalidPattern, "{\"frames_pattern\":\"{frame}{frame}\",\"from\":0,\"to\":1}" },
        .{ error.InvalidBound, "{\"frames_pattern\":\"{frame}\",\"from\":-1,\"to\":1}" },
        .{ error.EmptyFrames, "{\"frames\":[]}" },
        .{ error.EmptyFrameKey, "{\"frames\":[\"\"]}" },
        .{ error.ConflictingFrames, "{\"frames\":[\"a\"],\"from\":0}" },
        .{ error.UnknownField, "{\"frames\":[\"a\"],\"markers\":[]}" },
    };
    inline for (clips) |case| {
        const text = "{\"version\":1,\"clips\":{\"x\":" ++ case[1] ++ "}}";
        try t.expectError(case[0], Definition.parse(t.allocator, text));
    }
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var def = try Definition.parse(a, source);
    defer def.deinit();
}

test "every allocation failure releases partial parsing and expanded keys" {
    try t.checkAllAllocationFailures(t.allocator, allocationProbe, .{});
}

test "255 frames accepted and plain placeholder preserves exact keys" {
    var def = try Definition.parse(t.allocator,
        \\{"version":1,"clips":{"x":{"frames_pattern":"tiles/{frame}","from":0,"to":254}}}
    );
    defer def.deinit();
    try t.expectEqual(@as(usize, 255), def.clips[0].frames.len);
    try t.expectEqualStrings("tiles/254", def.clips[0].frames[254]);
}

test "resource validation is explicit and identifies the missing clip frame and key" {
    var def = try Definition.parse(t.allocator, source);
    defer def.deinit();
    const Lookup = struct {
        fn contains(missing: ?[]const u8, key: []const u8) bool {
            return if (missing) |m| !std.mem.eql(u8, m, key) else true;
        }
    };
    const missing = def.firstMissingFrame(@as(?[]const u8, "walk_0002.png"), Lookup.contains).?;
    try t.expectEqualStrings("walk", missing.clip);
    try t.expectEqual(@as(usize, 1), missing.index);
    try t.expectEqualStrings("walk_0002.png", missing.key);
    try t.expect(def.firstMissingFrame(@as(?[]const u8, null), Lookup.contains) == null);
}

test "duplicate clip and malformed JSON are rejected without leaks" {
    try t.expectError(error.DuplicateClip, Definition.parse(t.allocator,
        \\{"version":1,"clips":{"x":{"frames":["a"]},"x":{"frames":["b"]}}}
    ));
    try t.expectError(error.ExpectedObject, Definition.parse(t.allocator, "[]"));
    try t.expectError(error.UnexpectedEof, Definition.parse(t.allocator, "{"));
}
