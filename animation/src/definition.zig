const std = @import("std");
const jsonc = @import("jsonc");
const FrameRange = @import("frame_range.zig").FrameRange;

pub const Clip = struct {
    name: []const u8,
    frames: []const []const u8,
};

/// Shared immutable authoring data. Playback state belongs to the entity.
/// This first schema intentionally accepts only version and clip frame keys.
/// Reject unsupported fields rather than pretending triggers/markers are live.
pub const Definition = struct {
    arena: std.heap.ArenaAllocator,
    clips: []const Clip,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Definition {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        // The JSONC value tree may borrow strings from its source.
        const owned = try a.dupe(u8, source);
        var parser = jsonc.JsoncParser.init(a, owned);
        const value = try parser.parse();
        if (parser.pos != owned.len) return error.TrailingData;
        const root = try object(value);
        try fields(root, &.{ "version", "clips" });
        if (root.getInteger("version") != 1) return error.UnsupportedVersion;
        const clips_obj = try object(root.get("clips") orelse return error.MissingClips);
        if (clips_obj.entries.len == 0) return error.EmptyClips;
        const clips = try a.alloc(Clip, clips_obj.entries.len);
        for (clips_obj.entries, 0..) |entry, i| {
            if (entry.key.len == 0) return error.EmptyClipName;
            for (clips[0..i]) |prior| if (std.mem.eql(u8, prior.name, entry.key)) return error.DuplicateClip;
            const data = try object(entry.value);
            try fields(data, &.{ "frames", "frames_pattern", "from", "to" });
            var frames: []const []const u8 = undefined;
            if (data.get("frames")) |explicit| {
                if (data.get("frames_pattern") != null or data.get("from") != null or data.get("to") != null)
                    return error.ConflictingFrames;
                const list = switch (explicit) {
                    .array => |v| v.items,
                    else => return error.ExpectedArray,
                };
                if (list.len == 0) return error.EmptyFrames;
                if (list.len > FrameRange.max_frames) return error.TooManyFrames;
                const keys = try a.alloc([]const u8, list.len);
                for (list, 0..) |item, n| {
                    keys[n] = switch (item) {
                        .string => |s| s,
                        else => return error.ExpectedString,
                    };
                    if (keys[n].len == 0) return error.EmptyFrameKey;
                }
                frames = keys;
            } else {
                const pattern = data.getString("frames_pattern") orelse return error.MissingPattern;
                frames = try (FrameRange{
                    .pattern = pattern,
                    .from = try bound(data, "from"),
                    .to = try bound(data, "to"),
                }).expand(a);
            }
            clips[i] = .{ .name = entry.key, .frames = frames };
        }
        return .{ .arena = arena, .clips = clips };
    }

    pub fn deinit(self: *Definition) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Definition, name: []const u8) ?*const Clip {
        for (self.clips) |*clip| if (std.mem.eql(u8, name, clip.name)) return clip;
        return null;
    }

    pub const MissingFrame = struct { clip: []const u8, index: usize, key: []const u8 };

    /// The resource owner calls this AFTER its atlas is ready. Parsing never
    /// confuses asynchronous loading with a missing sprite. Returned names are
    /// borrowed from this definition; no renderer or atlas type is required.
    pub fn firstMissingFrame(self: *const Definition, context: anytype, hasFrame: anytype) ?MissingFrame {
        for (self.clips) |clip| {
            for (clip.frames, 0..) |key, index| {
                if (!hasFrame(context, key)) return .{ .clip = clip.name, .index = index, .key = key };
            }
        }
        return null;
    }
};

fn object(value: jsonc.Value) !jsonc.Value.Object {
    return switch (value) {
        .object => |o| o,
        else => error.ExpectedObject,
    };
}

fn fields(obj: jsonc.Value.Object, allowed: []const []const u8) !void {
    for (obj.entries, 0..) |entry, i| {
        for (obj.entries[0..i]) |prior| if (std.mem.eql(u8, prior.key, entry.key)) return error.DuplicateField;
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.key)) break;
        } else return error.UnknownField;
    }
}

fn bound(obj: jsonc.Value.Object, name: []const u8) !u32 {
    const number = obj.getInteger(name) orelse return error.InvalidBound;
    return std.math.cast(u32, number) orelse error.InvalidBound;
}
