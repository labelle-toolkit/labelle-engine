const std = @import("std");
const zspec = @import("zspec");
const scanner = @import("../generator/scanner.zig");

test {
    zspec.runAll(@This());
}

/// Get the absolute path of a TmpDir for use with scanFolder (which opens relative to cwd)
fn tmpDirPath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return try tmp.dir.realpath(".", buf);
}

/// Free a slice of string slices returned by scan functions
fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// Sort a mutable slice of string slices for deterministic comparison
fn sortNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

pub const SCAN_FOLDER = struct {
    test "returns zig file names without extension" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Create test files
        const files = [_][]const u8{ "player.zig", "enemy.zig", "readme.txt" };
        for (files) |name| {
            const file = try tmp.dir.createFile(name, .{});
            file.close();
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const names = try scanner.scanFolder(std.testing.allocator, path);
        defer freeNames(std.testing.allocator, names);

        try std.testing.expectEqual(@as(usize, 2), names.len);

        // Sort for deterministic comparison (directory iteration order is not guaranteed)
        var sorted: [2][]const u8 = undefined;
        @memcpy(&sorted, names);
        sortNames(&sorted);
        try std.testing.expectEqualStrings("enemy", sorted[0]);
        try std.testing.expectEqualStrings("player", sorted[1]);
    }

    test "returns empty for non-existent path" {
        const names = try scanner.scanFolder(std.testing.allocator, "/tmp/labelle_nonexistent_test_dir_xyz");
        defer freeNames(std.testing.allocator, names);
        try std.testing.expectEqual(@as(usize, 0), names.len);
    }

    test "returns empty for directory with no zig files" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const files = [_][]const u8{ "readme.txt", "data.json" };
        for (files) |name| {
            const file = try tmp.dir.createFile(name, .{});
            file.close();
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const names = try scanner.scanFolder(std.testing.allocator, path);
        defer freeNames(std.testing.allocator, names);
        try std.testing.expectEqual(@as(usize, 0), names.len);
    }
};

pub const SCAN_ZON_FOLDER = struct {
    test "returns zon file names without extension" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const files = [_][]const u8{ "level1.zon", "level2.zon", "notes.txt" };
        for (files) |name| {
            const file = try tmp.dir.createFile(name, .{});
            file.close();
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const names = try scanner.scanZonFolder(std.testing.allocator, path);
        defer freeNames(std.testing.allocator, names);

        try std.testing.expectEqual(@as(usize, 2), names.len);

        var sorted: [2][]const u8 = undefined;
        @memcpy(&sorted, names);
        sortNames(&sorted);
        try std.testing.expectEqualStrings("level1", sorted[0]);
        try std.testing.expectEqualStrings("level2", sorted[1]);
    }

    test "returns empty for non-existent path" {
        const names = try scanner.scanZonFolder(std.testing.allocator, "/tmp/labelle_nonexistent_test_dir_xyz");
        defer freeNames(std.testing.allocator, names);
        try std.testing.expectEqual(@as(usize, 0), names.len);
    }
};
