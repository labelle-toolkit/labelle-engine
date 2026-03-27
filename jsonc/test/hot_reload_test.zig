const std = @import("std");
const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const HotReloader = jsonc.HotReloader;

pub const HotReloaderSpec = struct {
    pub const snapshot = struct {
        test "snapshotFileTimes captures mtimes for existing files" {
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            // Create a scene file and a prefab file
            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{}" });
            try tmp_dir.dir.makeDir("prefabs");
            const prefabs_dir = try tmp_dir.dir.openDir("prefabs", .{});
            _ = prefabs_dir;
            try tmp_dir.dir.writeFile(.{ .sub_path = "prefabs/player.jsonc", .data = "{}" });

            const scene_path = try tmpDirPath(tmp_dir, "scene.jsonc");
            defer std.testing.allocator.free(scene_path);
            const prefab_path = try tmpDirPath(tmp_dir, "prefabs");
            defer std.testing.allocator.free(prefab_path);

            var reloader = HotReloader.init(std.testing.allocator, scene_path, prefab_path);
            defer reloader.deinit();

            reloader.snapshotFileTimes();

            // Should have recorded at least the scene file
            try expect.isTrue(reloader.snapshots.count() > 0);
        }
    };

    pub const no_changes = struct {
        test "hasFileChanges returns false when nothing changed" {
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{}" });
            try tmp_dir.dir.makeDir("prefabs");

            const scene_path = try tmpDirPath(tmp_dir, "scene.jsonc");
            defer std.testing.allocator.free(scene_path);
            const prefab_path = try tmpDirPath(tmp_dir, "prefabs");
            defer std.testing.allocator.free(prefab_path);

            var reloader = HotReloader.init(std.testing.allocator, scene_path, prefab_path);
            defer reloader.deinit();

            reloader.snapshotFileTimes();

            try expect.isFalse(reloader.hasFileChanges());
        }
    };

    pub const detect_changes = struct {
        test "hasFileChanges returns true after file modification" {
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{}" });
            try tmp_dir.dir.makeDir("prefabs");

            const scene_path = try tmpDirPath(tmp_dir, "scene.jsonc");
            defer std.testing.allocator.free(scene_path);
            const prefab_path = try tmpDirPath(tmp_dir, "prefabs");
            defer std.testing.allocator.free(prefab_path);

            var reloader = HotReloader.init(std.testing.allocator, scene_path, prefab_path);
            defer reloader.deinit();

            reloader.snapshotFileTimes();

            // Sleep to ensure mtime changes
            std.time.sleep(10 * std.time.ns_per_ms);

            // Modify the file
            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{ \"changed\": true }" });

            try expect.isTrue(reloader.hasFileChanges());
        }
    };

    pub const force_reload = struct {
        test "forceReload sets dirty flag" {
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{}" });
            try tmp_dir.dir.makeDir("prefabs");

            const scene_path = try tmpDirPath(tmp_dir, "scene.jsonc");
            defer std.testing.allocator.free(scene_path);
            const prefab_path = try tmpDirPath(tmp_dir, "prefabs");
            defer std.testing.allocator.free(prefab_path);

            var reloader = HotReloader.init(std.testing.allocator, scene_path, prefab_path);
            defer reloader.deinit();

            try expect.isFalse(reloader.dirty);
            try expect.isFalse(reloader.poll());

            reloader.forceReload();

            try expect.isTrue(reloader.dirty);
            try expect.isTrue(reloader.poll());

            reloader.resetDirtyFlag();
            try expect.isFalse(reloader.dirty);
        }
    };

    pub const poll_no_leak = struct {
        test "100 consecutive polls do not leak" {
            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{ .sub_path = "scene.jsonc", .data = "{}" });
            try tmp_dir.dir.makeDir("prefabs");
            try tmp_dir.dir.writeFile(.{ .sub_path = "prefabs/a.jsonc", .data = "{}" });
            try tmp_dir.dir.writeFile(.{ .sub_path = "prefabs/b.zon", .data = ".{}" });

            const scene_path = try tmpDirPath(tmp_dir, "scene.jsonc");
            defer std.testing.allocator.free(scene_path);
            const prefab_path = try tmpDirPath(tmp_dir, "prefabs");
            defer std.testing.allocator.free(prefab_path);

            var reloader = HotReloader.init(std.testing.allocator, scene_path, prefab_path);
            defer reloader.deinit();

            reloader.snapshotFileTimes();

            // Poll 100 times — allocator leak detection will catch issues
            for (0..100) |_| {
                _ = reloader.poll();
            }
        }
    };
};

/// Build an absolute path from a tmpDir + relative sub-path.
fn tmpDirPath(tmp_dir: std.testing.TmpDir, sub: []const u8) ![]const u8 {
    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir_path, sub });
}
