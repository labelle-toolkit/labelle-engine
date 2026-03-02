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

pub const EXTRACT_TYPE_NAMES = struct {
    /// Helper to write a file with content in a temp dir
    fn writeFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
        const file = try dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(content);
    }

    test "extracts struct type name from source file" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "workstation.zig",
            \\const std = @import("std");
            \\
            \\pub const Workstation = struct {
            \\    name: []const u8 = "",
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"workstation"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqual(@as(usize, 1), type_names.len);
        try std.testing.expectEqualStrings("Workstation", type_names[0]);
    }

    test "extracts union type name" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "current_task.zig",
            \\pub const CurrentTask = union(enum) {
            \\    idle,
            \\    working: u32,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"current_task"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqualStrings("CurrentTask", type_names[0]);
    }

    test "extracts enum type name" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "items.zig",
            \\pub const Items = enum {
            \\    Flour,
            \\    Water,
            \\    Bread,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"items"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqualStrings("Items", type_names[0]);
    }

    test "extracts name that differs from filename PascalCase" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "http_client.zig",
            \\const std = @import("std");
            \\
            \\pub const HTTPClient = struct {
            \\    url: []const u8 = "",
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"http_client"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        // Should be "HTTPClient" (from source), NOT "HttpClient" (from PascalCase)
        try std.testing.expectEqualStrings("HTTPClient", type_names[0]);
    }

    test "falls back to PascalCase for missing file" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"my_component"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqualStrings("MyComponent", type_names[0]);
    }

    test "falls back to PascalCase for file without pub const type" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "helpers.zig",
            \\pub fn doSomething() void {}
            \\const x: u32 = 42;
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"helpers"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqualStrings("Helpers", type_names[0]);
    }

    test "handles multiple files" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "eis.zig", "pub const Eis = struct { workstation: u64 = 0 };");
        try writeFile(tmp.dir, "iis.zig", "pub const Iis = struct { workstation: u64 = 0 };");

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{ "eis", "iis" };
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        try std.testing.expectEqual(@as(usize, 2), type_names.len);
        try std.testing.expectEqualStrings("Eis", type_names[0]);
        try std.testing.expectEqualStrings("Iis", type_names[1]);
    }

    test "extracts all-caps type name like EIS" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "eis.zig",
            \\const std = @import("std");
            \\
            \\pub const EIS = struct {
            \\    workstation: u64 = 0,
            \\    item: u32 = 0,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"eis"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        // Should be "EIS" (from source), NOT "Eis" (from PascalCase fallback)
        try std.testing.expectEqualStrings("EIS", type_names[0]);
    }

    test "skips commented-out pub const" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "widget.zig",
            \\// pub const OldWidget = struct {};
            \\pub const Widget = struct {
            \\    x: u32 = 0,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"widget"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        // Should skip the commented-out OldWidget and find Widget
        try std.testing.expectEqualStrings("Widget", type_names[0]);
    }

    test "does not match enum prefix in longer word like enumerate" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // "enumerate" starts with "enum" but is not the keyword "enum"
        try writeFile(tmp.dir, "values.zig",
            \\pub const BadMatch = enumerate(.{ .a, .b });
            \\pub const Values = enum {
            \\    a,
            \\    b,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"values"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        // Should skip BadMatch (enumerate is not the keyword "enum") and find Values
        try std.testing.expectEqualStrings("Values", type_names[0]);
    }

    test "skips non-type pub const (e.g. pub const x = 42)" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "config.zig",
            \\pub const MAX_SIZE = 1024;
            \\pub const Config = struct {
            \\    size: u32 = 0,
            \\};
        );

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tmpDirPath(&tmp, &buf);

        const filenames = &[_][]const u8{"config"};
        const type_names = try scanner.extractTypeNames(std.testing.allocator, path, filenames);
        defer freeNames(std.testing.allocator, type_names);

        // Should skip MAX_SIZE (not a type) and find Config
        try std.testing.expectEqualStrings("Config", type_names[0]);
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
