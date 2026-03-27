const std = @import("std");

/// Watches scene and prefab files for modification-time changes.
/// Does NOT load scenes — only detects when files changed so the
/// caller (engine / game) can trigger a reload.
pub const HotReloader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    scene_path: []const u8,
    prefab_dir: []const u8,

    /// Recorded mtimes from the last snapshot (path -> mtime in ns).
    snapshots: std.StringHashMap(i128),

    /// Set by `forceReload()` or when `poll()` detects changes.
    dirty: bool = false,

    // Stats
    reload_count: u64 = 0,
    last_reload_time_ns: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, scene_path: []const u8, prefab_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .scene_path = scene_path,
            .prefab_dir = prefab_dir,
            .snapshots = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.snapshots.deinit();
    }

    /// Record the current mtime for the scene file and every .jsonc / .zon
    /// file in the prefab directory.
    pub fn snapshotFileTimes(self: *Self) void {
        // Clear previous snapshot
        var old_it = self.snapshots.iterator();
        while (old_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.snapshots.clearRetainingCapacity();

        // Snapshot the scene file itself
        self.snapshotFile(self.scene_path);

        // Walk prefab directory
        self.snapshotDir(self.prefab_dir);
    }

    /// Returns true if any watched file has a different mtime than the snapshot.
    pub fn hasFileChanges(self: *Self) bool {
        // Check scene file
        if (self.fileChanged(self.scene_path)) return true;

        // Check prefab directory
        if (self.dirHasChanges(self.prefab_dir)) return true;

        return false;
    }

    /// Signal that a reload should happen regardless of file changes.
    pub fn forceReload(self: *Self) void {
        self.dirty = true;
    }

    /// Check for file changes; returns true if a reload is needed
    /// (either from file changes or a prior `forceReload` call).
    pub fn poll(self: *Self) bool {
        if (self.dirty) return true;

        if (self.hasFileChanges()) {
            self.dirty = true;
            self.reload_count += 1;
            self.last_reload_time_ns = std.time.nanoTimestamp();
            return true;
        }

        return false;
    }

    /// Clear the dirty state after the caller has handled the reload.
    pub fn resetDirtyFlag(self: *Self) void {
        self.dirty = false;
    }

    // ── Internal helpers ─────────────────────────────────────────

    fn snapshotFile(self: *Self, path: []const u8) void {
        const mtime = getFileMtime(path) orelse return;
        const key = self.allocator.dupe(u8, path) catch return;
        self.snapshots.put(key, mtime) catch {
            self.allocator.free(key);
        };
    }

    fn snapshotDir(self: *Self, dir_path: []const u8) void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!isWatchedExt(entry.name)) continue;

            // Build full path
            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            self.snapshotFile(full);
            self.allocator.free(full);
        }
    }

    fn fileChanged(self: *Self, path: []const u8) bool {
        const current_mtime = getFileMtime(path) orelse return false;
        if (self.snapshots.get(path)) |snapshot_mtime| {
            return current_mtime != snapshot_mtime;
        }
        // File wasn't in snapshot — it's new, treat as changed
        return true;
    }

    fn dirHasChanges(self: *Self, dir_path: []const u8) bool {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return false;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!isWatchedExt(entry.name)) continue;

            const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            defer self.allocator.free(full);

            if (self.fileChanged(full)) return true;
        }
        return false;
    }

    fn getFileMtime(path: []const u8) ?i128 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        return stat.mtime;
    }

    fn isWatchedExt(name: []const u8) bool {
        return std.mem.endsWith(u8, name, ".jsonc") or std.mem.endsWith(u8, name, ".zon");
    }
};
