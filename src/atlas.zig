/// Texture atlas — compile-time (.zon) and runtime sprite lookup.
/// Ported from v1. Supports TexturePacker frame format.
const std = @import("std");

/// Per-sprite data in an atlas.
pub const SpriteData = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    source_width: u32 = 0,
    source_height: u32 = 0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    rotated: bool = false,
    trimmed: bool = false,
    name: []const u8 = "",

    /// Actual display width (accounts for rotation in atlas).
    pub fn getWidth(self: SpriteData) u32 {
        if (self.rotated) return self.height;
        return self.width;
    }

    /// Actual display height (accounts for rotation in atlas).
    pub fn getHeight(self: SpriteData) u32 {
        if (self.rotated) return self.width;
        return self.height;
    }

    /// Source width (original before trimming), or display width if not trimmed.
    pub fn getSourceWidth(self: SpriteData) u32 {
        if (self.source_width > 0) return self.source_width;
        return self.getWidth();
    }

    /// Source height (original before trimming), or display height if not trimmed.
    pub fn getSourceHeight(self: SpriteData) u32 {
        if (self.source_height > 0) return self.source_height;
        return self.getHeight();
    }
};

/// Compile-time atlas from a .zon frame definition.
/// Usage:
///   const atlas = ComptimeAtlas(@import("characters_frames.zon"));
///   const sprite = atlas.get("idle_0001").?;
pub fn ComptimeAtlas(comptime frames: anytype) type {
    const fields = @typeInfo(@TypeOf(frames)).@"struct".fields;

    return struct {
        pub const count: usize = fields.len;

        pub const sprites: [fields.len]SpriteData = blk: {
            var result: [fields.len]SpriteData = undefined;
            for (fields, 0..) |field, i| {
                const f = @field(frames, field.name);
                result[i] = .{
                    .x = @intCast(f.x),
                    .y = @intCast(f.y),
                    .width = @intCast(f.w),
                    .height = @intCast(f.h),
                    .rotated = f.rotated,
                    .trimmed = f.trimmed,
                    .source_width = @intCast(f.orig_w),
                    .source_height = @intCast(f.orig_h),
                    .offset_x = @intCast(f.source_x),
                    .offset_y = @intCast(f.source_y),
                    .name = field.name,
                };
            }
            break :blk result;
        };

        pub const names: [fields.len][]const u8 = blk: {
            var result: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, i| {
                result[i] = field.name;
            }
            break :blk result;
        };

        /// Runtime lookup by name.
        pub fn get(name: []const u8) ?SpriteData {
            for (sprites) |s| {
                if (std.mem.eql(u8, s.name, name)) return s;
            }
            return null;
        }

        /// Compile-time lookup by name.
        pub fn getComptime(comptime name: []const u8) SpriteData {
            return @field(frames, name);
        }

        pub fn has(name: []const u8) bool {
            return get(name) != null;
        }
    };
}

/// Runtime atlas backed by a hashmap. For JSON/dynamic loading.
pub const RuntimeAtlas = struct {
    sprites: std.StringHashMap(SpriteData),
    texture_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) RuntimeAtlas {
        return .{ .sprites = std.StringHashMap(SpriteData).init(allocator) };
    }

    pub fn deinit(self: *RuntimeAtlas) void {
        self.sprites.deinit();
    }

    pub fn addSprite(self: *RuntimeAtlas, name: []const u8, data: SpriteData) !void {
        try self.sprites.put(name, data);
    }

    pub fn get(self: *const RuntimeAtlas, name: []const u8) ?SpriteData {
        return self.sprites.get(name);
    }

    pub fn has(self: *const RuntimeAtlas, name: []const u8) bool {
        return self.sprites.contains(name);
    }

    pub fn count(self: *const RuntimeAtlas) usize {
        return self.sprites.count();
    }
};

/// Texture manager — unified API for multiple atlases.
pub const TextureManager = struct {
    atlases: std.StringHashMap(RuntimeAtlas),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TextureManager {
        return .{
            .atlases = std.StringHashMap(RuntimeAtlas).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextureManager) void {
        var it = self.atlases.valueIterator();
        while (it.next()) |atlas| {
            atlas.deinit();
        }
        self.atlases.deinit();
    }

    /// Register a new atlas by name.
    pub fn addAtlas(self: *TextureManager, name: []const u8) !*RuntimeAtlas {
        try self.atlases.put(name, RuntimeAtlas.init(self.allocator));
        return self.atlases.getPtr(name).?;
    }

    /// Get an atlas by name.
    pub fn getAtlas(self: *const TextureManager, name: []const u8) ?*const RuntimeAtlas {
        return self.atlases.getPtr(name);
    }

    /// Search all atlases for a sprite by name.
    pub fn findSprite(self: *const TextureManager, sprite_name: []const u8) ?SpriteData {
        var it = self.atlases.valueIterator();
        while (it.next()) |atlas| {
            if (atlas.get(sprite_name)) |data| return data;
        }
        return null;
    }

    pub fn atlasCount(self: *const TextureManager) usize {
        return self.atlases.count();
    }
};
