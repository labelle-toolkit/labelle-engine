const std = @import("std");
const zspec = @import("zspec");
const fingerprint = @import("../generator/fingerprint.zig");

test {
    zspec.runAll(@This());
}

pub const PARSE_FINGERPRINT = struct {
    test "parses suggested value pattern" {
        const output = "missing top-level 'fingerprint' field; suggested value: 0xbc20e1ab89c1b519";
        const result = fingerprint.parseFingerprint(output);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u64, 0xbc20e1ab89c1b519), result.?);
    }

    test "parses use this value pattern" {
        const output = "invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0xdef456abc789";
        const result = fingerprint.parseFingerprint(output);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u64, 0xdef456abc789), result.?);
    }

    test "returns null for no match" {
        const output = "some unrelated error output";
        const result = fingerprint.parseFingerprint(output);
        try std.testing.expect(result == null);
    }

    test "returns null for empty string" {
        const result = fingerprint.parseFingerprint("");
        try std.testing.expect(result == null);
    }

    test "parses fingerprint with trailing content" {
        const output = "suggested value: 0xabc123\nmore output follows";
        const result = fingerprint.parseFingerprint(output);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u64, 0xabc123), result.?);
    }
};
