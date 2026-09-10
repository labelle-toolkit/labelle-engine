const std = @import("std");

pub const FrameRange = struct {
    pattern: []const u8,
    from: u32,
    to: u32,

    /// Existing SpriteAnimation uses u8 frame counts. Keep this explicit until
    /// playback migration widens the representation.
    pub const max_frames = 255;

    /// Result and strings belong to `arena`; callers release the entire arena.
    pub fn expand(self: FrameRange, arena: std.mem.Allocator) ![]const []const u8 {
        if (self.from > self.to) return error.ReversedRange;
        const count64 = @as(u64, self.to) - self.from + 1;
        if (count64 > max_frames) return error.TooManyFrames;
        const open = std.mem.indexOfScalar(u8, self.pattern, '{') orelse return error.InvalidPattern;
        const close = std.mem.indexOfScalarPos(u8, self.pattern, open, '}') orelse return error.InvalidPattern;
        const prefix = self.pattern[0..open];
        const suffix = self.pattern[close + 1 ..];
        if (std.mem.indexOfScalar(u8, prefix, '}') != null or
            std.mem.indexOfAny(u8, suffix, "{}") != null) return error.InvalidPattern;
        const token = self.pattern[open + 1 .. close];
        var width: usize = 0;
        if (!std.mem.eql(u8, token, "frame")) {
            if (!std.mem.startsWith(u8, token, "frame:0")) return error.InvalidPattern;
            const digits = token[7..];
            if (digits.len == 0 or digits.len > 2) return error.InvalidPattern;
            for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidPattern;
            width = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidPattern;
            if (width == 0 or width > 10) return error.InvalidPattern;
        }
        const frames = try arena.alloc([]const u8, @intCast(count64));
        for (frames, 0..) |*frame, i| {
            var buf: [10]u8 = undefined;
            const number = try std.fmt.bufPrint(&buf, "{d}", .{self.from + @as(u32, @intCast(i))});
            const padded = @max(width, number.len);
            const size = try std.math.add(usize, try std.math.add(usize, prefix.len, padded), suffix.len);
            const key = try arena.alloc(u8, size);
            @memcpy(key[0..prefix.len], prefix);
            @memset(key[prefix.len .. prefix.len + padded - number.len], '0');
            @memcpy(key[prefix.len + padded - number.len .. prefix.len + padded], number);
            @memcpy(key[prefix.len + padded ..], suffix);
            frame.* = key;
        }
        return frames;
    }
};
