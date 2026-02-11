const std = @import("std");
const zspec = @import("zspec");
const version = @import("../generator/version.zig");

const Version = version.Version;
const PluginCompatibility = version.PluginCompatibility;

test {
    zspec.runAll(@This());
}

pub const VERSION_PARSE = struct {
    test "parses valid semver '1.2.3'" {
        const v = try Version.parse("1.2.3");
        try std.testing.expectEqual(@as(u32, 1), v.major);
        try std.testing.expectEqual(@as(u32, 2), v.minor);
        try std.testing.expectEqual(@as(u32, 3), v.patch);
    }

    test "strips v prefix from 'v1.2.3'" {
        const v = try Version.parse("v1.2.3");
        try std.testing.expectEqual(@as(u32, 1), v.major);
        try std.testing.expectEqual(@as(u32, 2), v.minor);
        try std.testing.expectEqual(@as(u32, 3), v.patch);
    }

    test "parses zero version '0.0.0'" {
        const v = try Version.parse("0.0.0");
        try std.testing.expectEqual(@as(u32, 0), v.major);
        try std.testing.expectEqual(@as(u32, 0), v.minor);
        try std.testing.expectEqual(@as(u32, 0), v.patch);
    }

    test "returns error for missing parts '1.2'" {
        const result = Version.parse("1.2");
        try std.testing.expectError(error.InvalidVersion, result);
    }

    test "returns error for single number '1'" {
        const result = Version.parse("1");
        try std.testing.expectError(error.InvalidVersion, result);
    }

    test "returns error for empty string" {
        const result = Version.parse("");
        try std.testing.expectError(error.InvalidVersion, result);
    }
};

pub const VERSION_FORMAT = struct {
    fn formatVersion(v: Version, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        try v.format("", .{}, fbs.writer());
        return fbs.getWritten();
    }

    test "formats as major.minor.patch" {
        const v = Version{ .major = 1, .minor = 2, .patch = 3 };
        var buf: [32]u8 = undefined;
        const formatted = try formatVersion(v, &buf);
        try std.testing.expectEqualStrings("1.2.3", formatted);
    }

    test "roundtrips through parse and format" {
        const original = "10.20.30";
        const v = try Version.parse(original);
        var buf: [32]u8 = undefined;
        const formatted = try formatVersion(v, &buf);
        try std.testing.expectEqualStrings(original, formatted);
    }
};

pub const VERSION_LT = struct {
    test "returns true when major is less" {
        const a = Version{ .major = 1, .minor = 0, .patch = 0 };
        const b = Version{ .major = 2, .minor = 0, .patch = 0 };
        try std.testing.expect(a.lt(b));
    }

    test "returns true when minor is less" {
        const a = Version{ .major = 1, .minor = 1, .patch = 0 };
        const b = Version{ .major = 1, .minor = 2, .patch = 0 };
        try std.testing.expect(a.lt(b));
    }

    test "returns true when patch is less" {
        const a = Version{ .major = 1, .minor = 0, .patch = 1 };
        const b = Version{ .major = 1, .minor = 0, .patch = 2 };
        try std.testing.expect(a.lt(b));
    }

    test "returns false for equal versions" {
        const v = Version{ .major = 1, .minor = 2, .patch = 3 };
        try std.testing.expect(!v.lt(v));
    }

    test "returns false when greater" {
        const a = Version{ .major = 2, .minor = 0, .patch = 0 };
        const b = Version{ .major = 1, .minor = 0, .patch = 0 };
        try std.testing.expect(!a.lt(b));
    }
};

pub const VERSION_GTE = struct {
    test "returns true for equal versions" {
        const v = Version{ .major = 1, .minor = 2, .patch = 3 };
        try std.testing.expect(v.gte(v));
    }

    test "returns true when greater" {
        const a = Version{ .major = 2, .minor = 0, .patch = 0 };
        const b = Version{ .major = 1, .minor = 0, .patch = 0 };
        try std.testing.expect(a.gte(b));
    }

    test "returns false when less" {
        const a = Version{ .major = 1, .minor = 0, .patch = 0 };
        const b = Version{ .major = 2, .minor = 0, .patch = 0 };
        try std.testing.expect(!a.gte(b));
    }
};

pub const PLUGIN_COMPATIBILITY = struct {
    test "returns compatible when within range" {
        const compat = PluginCompatibility{
            .name = "test-plugin",
            .min_version = Version{ .major = 1, .minor = 0, .patch = 0 },
            .max_version = Version{ .major = 2, .minor = 0, .patch = 0 },
            .reason = "test",
            .allocator = std.testing.allocator,
        };
        const result = compat.checkCompatibility(Version{ .major = 1, .minor = 5, .patch = 0 });
        try std.testing.expectEqual(.compatible, result);
    }

    test "returns compatible at min version" {
        const compat = PluginCompatibility{
            .name = "test-plugin",
            .min_version = Version{ .major = 1, .minor = 0, .patch = 0 },
            .max_version = Version{ .major = 2, .minor = 0, .patch = 0 },
            .reason = "test",
            .allocator = std.testing.allocator,
        };
        const result = compat.checkCompatibility(Version{ .major = 1, .minor = 0, .patch = 0 });
        try std.testing.expectEqual(.compatible, result);
    }

    test "returns incompatible below min" {
        const compat = PluginCompatibility{
            .name = "test-plugin",
            .min_version = Version{ .major = 2, .minor = 0, .patch = 0 },
            .max_version = Version{ .major = 3, .minor = 0, .patch = 0 },
            .reason = "test",
            .allocator = std.testing.allocator,
        };
        const result = compat.checkCompatibility(Version{ .major = 1, .minor = 0, .patch = 0 });
        try std.testing.expectEqual(.incompatible, result);
    }

    test "returns untested at max version" {
        const compat = PluginCompatibility{
            .name = "test-plugin",
            .min_version = Version{ .major = 1, .minor = 0, .patch = 0 },
            .max_version = Version{ .major = 2, .minor = 0, .patch = 0 },
            .reason = "test",
            .allocator = std.testing.allocator,
        };
        const result = compat.checkCompatibility(Version{ .major = 2, .minor = 0, .patch = 0 });
        try std.testing.expectEqual(.untested, result);
    }

    test "returns untested above max" {
        const compat = PluginCompatibility{
            .name = "test-plugin",
            .min_version = Version{ .major = 1, .minor = 0, .patch = 0 },
            .max_version = Version{ .major = 2, .minor = 0, .patch = 0 },
            .reason = "test",
            .allocator = std.testing.allocator,
        };
        const result = compat.checkCompatibility(Version{ .major = 3, .minor = 0, .patch = 0 });
        try std.testing.expectEqual(.untested, result);
    }
};
