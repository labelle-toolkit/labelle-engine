const std = @import("std");
const scene_loader = @import("scene_loader.zig");
const Scene = scene_loader.Scene;
const Allocator = std.mem.Allocator;

/// Hot-reload orchestrator for runtime scenes.
/// Watches scene and prefab files for changes (via mtime polling)
/// and reloads when modifications are detected.
pub const HotReloader = struct {
    scene_path: []const u8,
    prefab_dir: []const u8,
    allocator: Allocator,

    /// Current loaded scene (owned by scene_arena).
    current_scene: ?Scene,

    /// Arena for the current scene — swapped on reload for clean memory management.
    scene_arena: std.heap.ArenaAllocator,

    /// File modification times for change detection.
    watched_files: std.StringHashMap(i128),

    /// Callback invoked before a reload (teardown hook).
    on_before_reload: ?*const fn (scene: Scene) void,

    /// Callback invoked after a successful reload.
    on_after_reload: ?*const fn (scene: Scene) void,

    /// Stats
    reload_count: usize,
    last_reload_time_ns: u64,

    pub fn init(
        allocator: Allocator,
        scene_path: []const u8,
        prefab_dir: []const u8,
    ) HotReloader {
        return .{
            .scene_path = scene_path,
            .prefab_dir = prefab_dir,
            .allocator = allocator,
            .current_scene = null,
            .scene_arena = std.heap.ArenaAllocator.init(allocator),
            .watched_files = std.StringHashMap(i128).init(allocator),
            .on_before_reload = null,
            .on_after_reload = null,
            .reload_count = 0,
            .last_reload_time_ns = 0,
        };
    }

    pub fn deinit(self: *HotReloader) void {
        // Free all duped key strings in watched_files
        var iter = self.watched_files.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.scene_arena.deinit();
        self.watched_files.deinit();
    }

    /// Initial load. Must be called before polling.
    pub fn load(self: *HotReloader) !void {
        try self.forceReload();
    }

    /// Force an immediate reload from disk (e.g., triggered by F5 keypress).
    pub fn forceReload(self: *HotReloader) !void {
        try self.doReload();
        try self.snapshotFileTimes();
    }

    /// Poll for file changes. Call this once per frame (or on a timer).
    /// Returns true if a reload occurred.
    pub fn poll(self: *HotReloader) !bool {
        if (try self.hasFileChanges()) {
            try self.doReload();
            try self.snapshotFileTimes();
            return true;
        }
        return false;
    }

    /// Get the current scene. Returns null if not yet loaded.
    pub fn getScene(self: *const HotReloader) ?Scene {
        return self.current_scene;
    }

    fn doReload(self: *HotReloader) !void {
        var timer = std.time.Timer.start() catch null;

        // Notify before reload
        if (self.current_scene) |scene| {
            if (self.on_before_reload) |cb| cb(scene);
        }

        // Clear before arena reset to avoid dangling pointer on load failure
        self.current_scene = null;

        // Reset the arena — frees all memory from previous scene load
        _ = self.scene_arena.reset(.retain_capacity);

        const arena_alloc = self.scene_arena.allocator();

        // Load scene fresh from disk
        self.current_scene = try scene_loader.loadScene(
            arena_alloc,
            self.scene_path,
            self.prefab_dir,
        );

        if (timer) |*t| {
            self.last_reload_time_ns = t.read();
        }
        self.reload_count += 1;

        // Notify after reload
        if (self.current_scene) |scene| {
            if (self.on_after_reload) |cb| cb(scene);
        }
    }

    fn snapshotFileTimes(self: *HotReloader) !void {
        // Free all previously duped key strings before clearing the map
        var iter = self.watched_files.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.watched_files.clearRetainingCapacity();

        // Watch the scene file
        try self.watchFile(self.scene_path);

        // Watch all prefab files in the directory (skip if dir doesn't exist)
        var dir = std.fs.cwd().openDir(self.prefab_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonc")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.prefab_dir, entry.name });
                defer self.allocator.free(full_path);
                try self.watchFile(full_path);
            }
        }
    }

    fn watchFile(self: *HotReloader, path: []const u8) !void {
        const mtime = getFileMtime(path) orelse return;
        if (self.watched_files.fetchPut(try self.allocator.dupe(u8, path), mtime) catch null) |old| {
            self.allocator.free(old.key);
        }
    }

    fn hasFileChanges(self: *HotReloader) !bool {
        var iter = self.watched_files.iterator();
        while (iter.next()) |entry| {
            const current_mtime = getFileMtime(entry.key_ptr.*) orelse continue;
            if (current_mtime != entry.value_ptr.*) return true;
        }
        return false;
    }

    fn getFileMtime(path: []const u8) ?i128 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        return stat.mtime;
    }
};

/// Simulated game loop for testing hot reload behavior.
/// Not a real game — just demonstrates the reload cycle.
pub const SimulatedGame = struct {
    reloader: HotReloader,
    frame_count: usize,
    reload_log: std.ArrayList(ReloadEvent),

    pub const ReloadEvent = struct {
        frame: usize,
        entity_count: usize,
        scene_name: []const u8,
        reload_time_ns: u64,
    };

    pub fn init(allocator: Allocator, scene_path: []const u8, prefab_dir: []const u8) SimulatedGame {
        return .{
            .reloader = HotReloader.init(allocator, scene_path, prefab_dir),
            .frame_count = 0,
            .reload_log = .{},
        };
    }

    pub fn deinit(self: *SimulatedGame) void {
        // Free duped scene_name strings from reload log
        for (self.reload_log.items) |event| {
            self.reloader.allocator.free(event.scene_name);
        }
        self.reload_log.deinit(self.reloader.allocator);
        self.reloader.deinit();
    }

    /// Start the game — initial scene load.
    pub fn start(self: *SimulatedGame) !void {
        try self.reloader.load();
        try self.logReload();
    }

    /// Simulate one frame. Polls for file changes.
    pub fn tick(self: *SimulatedGame) !void {
        self.frame_count += 1;
        if (try self.reloader.poll()) {
            try self.logReload();
        }
    }

    /// Force a reload (simulates F5 keypress).
    pub fn reload(self: *SimulatedGame) !void {
        try self.reloader.forceReload();
        try self.logReload();
    }

    fn logReload(self: *SimulatedGame) !void {
        if (self.reloader.current_scene) |scene| {
            // Dupe scene_name onto the parent allocator so it survives arena resets
            const owned_name = try self.reloader.allocator.dupe(u8, scene.name);
            try self.reload_log.append(self.reloader.allocator, .{
                .frame = self.frame_count,
                .entity_count = scene.entities.len,
                .scene_name = owned_name,
                .reload_time_ns = self.reloader.last_reload_time_ns,
            });
        }
    }
};
