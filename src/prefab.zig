// Prefab system - runtime ZON-based prefabs
//
// Prefabs are ZON files that define sprite configuration for entities.
// The prefab name is derived from the filename (e.g., player.zon -> "player").
//
// Example prefab file (prefabs/player.zon):
// .{
//     .name = "player.png",
//     .x = 100,
//     .y = 200,
//     .scale = 2.0,
// }

const std = @import("std");
const labelle = @import("labelle");

// Re-export Pivot from labelle-gfx
pub const Pivot = labelle.Pivot;

// Z-index constants
pub const ZIndex = struct {
    pub const background: u8 = 0;
    pub const characters: u8 = 128;
    pub const foreground: u8 = 255;
};

/// Sprite configuration for prefabs
pub const SpriteConfig = struct {
    name: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    z_index: u8 = ZIndex.characters,
    scale: f32 = 1.0,
    rotation: f32 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    pivot: Pivot = .center,
    pivot_x: f32 = 0.5,
    pivot_y: f32 = 0.5,
};

/// Runtime prefab registry - loads and manages prefabs from ZON files
/// Prefab names are derived from filenames (e.g., player.zon -> "player")
pub const PrefabRegistry = struct {
    allocator: std.mem.Allocator,
    prefabs: std.StringHashMapUnmanaged(SpriteConfig),
    names: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) PrefabRegistry {
        return .{
            .allocator = allocator,
            .prefabs = .{},
            .names = .{},
        };
    }

    pub fn deinit(self: *PrefabRegistry) void {
        var iter = self.prefabs.iterator();
        while (iter.next()) |entry| {
            std.zon.parse.free(self.allocator, entry.value_ptr.*);
        }
        self.prefabs.deinit(self.allocator);
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
    }

    /// Load a prefab from a .zon file (name derived from filename)
    pub fn loadFromFile(self: *PrefabRegistry, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try self.allocator.allocSentinel(u8, stat.size, 0);
        defer self.allocator.free(content);

        const bytes_read = try file.readAll(content);
        if (bytes_read != stat.size) {
            return error.UnexpectedEof;
        }

        const sprite = try std.zon.parse.fromSlice(SpriteConfig, self.allocator, content, null, .{});
        errdefer std.zon.parse.free(self.allocator, sprite);

        // Extract name from filename (e.g., "prefabs/player.zon" -> "player")
        const basename = std.fs.path.basename(path);
        const name_end = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
        const name = try self.allocator.dupe(u8, basename[0..name_end]);
        errdefer self.allocator.free(name);

        try self.names.append(self.allocator, name);
        try self.prefabs.put(self.allocator, name, sprite);
    }

    /// Load all .zon files from a directory
    pub fn loadFolder(self: *PrefabRegistry, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zon")) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(full_path);
                try self.loadFromFile(full_path);
            }
        }
    }

    /// Get a prefab's sprite config by name
    pub fn get(self: *const PrefabRegistry, name: []const u8) ?SpriteConfig {
        return self.prefabs.get(name);
    }

    /// Check if a prefab exists
    pub fn has(self: *const PrefabRegistry, name: []const u8) bool {
        return self.prefabs.contains(name);
    }

    /// Get number of loaded prefabs
    pub fn count(self: *const PrefabRegistry) usize {
        return self.prefabs.count();
    }
};

/// Apply overrides from a comptime struct to a result struct
fn applyOverrides(result: anytype, comptime overrides: anytype) void {
    inline for (@typeInfo(@TypeOf(result.*)).@"struct".fields) |field| {
        if (@hasField(@TypeOf(overrides), field.name)) {
            @field(result, field.name) = @field(overrides, field.name);
        }
    }
}

/// Merge sprite config with overrides from scene data
pub fn mergeSpriteWithOverrides(
    base: SpriteConfig,
    comptime overrides: anytype,
) SpriteConfig {
    var result = base;

    // Apply top-level overrides (x, y, scale, etc. directly on entity def)
    applyOverrides(&result, overrides);

    // Apply nested sprite overrides (entity def has .sprite = .{ ... })
    if (@hasField(@TypeOf(overrides), "sprite")) {
        applyOverrides(&result, overrides.sprite);
    }

    return result;
}
