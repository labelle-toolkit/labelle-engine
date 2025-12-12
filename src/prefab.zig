// Prefab system - runtime ZON-based prefabs with component composition
//
// Prefabs are ZON files that define:
// - name: Unique identifier for the prefab
// - sprite: Visual configuration for the entity
// - animation: Optional default animation
// - children: Optional nested prefab references
//
// Example prefab file (prefabs/player.zon):
// .{
//     .name = "player",
//     .sprite = .{
//         .name = "player.png",
//         .x = 100,
//         .y = 200,
//         .scale = 2.0,
//     },
//     .children = .{
//         .weapon = "sword",
//         .items = .{ "potion", "potion" },
//     },
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

/// Children configuration for nested prefabs
pub const ChildrenConfig = struct {
    weapon: ?[]const u8 = null,
    offhand: ?[]const u8 = null,
    items: ?[]const []const u8 = null,
};

/// Prefab definition loaded from .zon files
pub const Prefab = struct {
    name: []const u8,
    sprite: SpriteConfig = .{},
    animation: ?[]const u8 = null,
    children: ChildrenConfig = .{},
};

/// Runtime prefab registry - loads and manages prefabs from ZON files
pub const PrefabRegistry = struct {
    allocator: std.mem.Allocator,
    prefabs: std.StringHashMap(Prefab),

    pub fn init(allocator: std.mem.Allocator) PrefabRegistry {
        return .{
            .allocator = allocator,
            .prefabs = std.StringHashMap(Prefab).init(allocator),
        };
    }

    pub fn deinit(self: *PrefabRegistry) void {
        var iter = self.prefabs.iterator();
        while (iter.next()) |entry| {
            std.zon.parse.free(self.allocator, entry.value_ptr.*);
        }
        self.prefabs.deinit();
    }

    /// Load a prefab from a .zon file
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

        const prefab = try std.zon.parse.fromSlice(Prefab, self.allocator, content, null, .{});
        errdefer std.zon.parse.free(self.allocator, prefab);

        try self.prefabs.put(prefab.name, prefab);
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

    /// Get a prefab by name
    pub fn get(self: *const PrefabRegistry, name: []const u8) ?Prefab {
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
