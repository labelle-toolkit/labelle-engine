/// Texture atlas — compile-time (.zon), runtime, and JSON-loaded sprite lookup.
/// Supports TexturePacker JSON Hash format.
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

/// Result of looking up a sprite by name across all loaded atlases.
///
/// `texture_scale_x` / `texture_scale_y` map the JSON's logical pixel grid
/// (the "meta.size" the atlas was authored against) onto the actual texture
/// pixel dims at load time. They are `1.0` for a 1:1 atlas (the common case)
/// and `< 1` when the user shipped a downscaled PNG without re-running
/// TexturePacker. Callers building a `SourceRect` for the renderer should
/// multiply x/y/w/h by the scale (so UV sampling tracks the smaller texture)
/// and pass the un-scaled `sprite.width/height` as the display dimensions.
pub const FindSpriteResult = struct {
    sprite: SpriteData,
    texture_id: u32,
    texture_scale_x: f32 = 1.0,
    texture_scale_y: f32 = 1.0,
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
    owns_keys: bool = false,
    /// Scale from the JSON's logical pixel grid to the actual texture's
    /// physical pixels. `1.0` when the atlas matches the texture; `< 1`
    /// when the source PNG was downscaled without re-running TexturePacker
    /// (a workflow we support to cut PNG decode time without touching
    /// the JSON or losing trim info). Stored separately per axis because
    /// nothing forces uniform scaling.
    texture_scale_x: f32 = 1.0,
    texture_scale_y: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator) RuntimeAtlas {
        return .{ .sprites = std.StringHashMap(SpriteData).init(allocator) };
    }

    pub fn deinit(self: *RuntimeAtlas) void {
        if (self.owns_keys) {
            var it = self.sprites.keyIterator();
            while (it.next()) |key| {
                self.sprites.allocator.free(key.*);
            }
        }
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

/// Texture manager — unified API for multiple atlases with JSON loading.
pub const TextureManager = struct {
    atlases: std.StringHashMap(RuntimeAtlas),
    allocator: std.mem.Allocator,
    version: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) TextureManager {
        return .{
            .atlases = std.StringHashMap(RuntimeAtlas).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextureManager) void {
        self.freeAllEntries();
        self.atlases.deinit();
    }

    /// Register a new empty atlas by name. Replaces any existing atlas with the same name.
    pub fn addAtlas(self: *TextureManager, name: []const u8) !*RuntimeAtlas {
        self.removeExisting(name);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.atlases.put(owned_name, RuntimeAtlas.init(self.allocator));
        self.version += 1;
        return self.atlases.getPtr(owned_name).?;
    }

    /// Texture dimensions for the actual loaded image. Used by the
    /// scale-aware atlas loaders to compute `texture_scale_*` against
    /// the JSON's `meta.size`. When the dims aren't known (e.g. the
    /// caller doesn't track them), passing `null` falls back to a
    /// scale of 1.0 — matching the legacy behavior.
    pub const TextureDims = struct {
        width: u32,
        height: u32,
    };

    /// Load an atlas from a TexturePacker JSON file and associate it with a texture.
    /// Replaces any existing atlas with the same name.
    pub fn loadAtlasFromJson(
        self: *TextureManager,
        name: []const u8,
        json_path: [:0]const u8,
        texture_id: u32,
        actual_dims: ?TextureDims,
    ) !void {
        var atlas = RuntimeAtlas.init(self.allocator);
        atlas.texture_id = texture_id;
        atlas.owns_keys = true;
        errdefer atlas.deinit();

        const meta = try parseTexturePackerJson(self.allocator, json_path, &atlas.sprites);
        applyTextureScale(&atlas, meta, actual_dims);

        self.removeExisting(name);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.atlases.put(owned_name, atlas);
        self.version += 1;
    }

    /// Load an atlas from JSON content already in memory.
    /// Replaces any existing atlas with the same name.
    pub fn loadAtlasFromJsonContent(
        self: *TextureManager,
        name: []const u8,
        json_content: []const u8,
        texture_id: u32,
        actual_dims: ?TextureDims,
    ) !void {
        var atlas = RuntimeAtlas.init(self.allocator);
        atlas.texture_id = texture_id;
        atlas.owns_keys = true;
        errdefer atlas.deinit();

        const meta = try parseTexturePackerJsonContent(self.allocator, json_content, &atlas.sprites);
        applyTextureScale(&atlas, meta, actual_dims);

        self.removeExisting(name);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.atlases.put(owned_name, atlas);
        self.version += 1;
    }

    /// Register an atlas from comptime sprite data (from ComptimeAtlas).
    /// Sprite names are comptime string literals — no heap allocation needed for keys.
    /// Replaces any existing atlas with the same name.
    pub fn loadAtlasComptime(
        self: *TextureManager,
        name: []const u8,
        comptime sprites: []const SpriteData,
        texture_id: u32,
    ) !void {
        var atlas = RuntimeAtlas.init(self.allocator);
        atlas.texture_id = texture_id;
        // Keys are comptime literals, no need to dupe or free them
        atlas.owns_keys = false;
        errdefer atlas.deinit();

        inline for (sprites) |sprite| {
            try atlas.sprites.put(sprite.name, sprite);
        }

        self.removeExisting(name);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.atlases.put(owned_name, atlas);
        self.version += 1;
    }

    /// Get an atlas by name.
    pub fn getAtlas(self: *const TextureManager, name: []const u8) ?*const RuntimeAtlas {
        return self.atlases.getPtr(name);
    }

    /// Search all atlases for a sprite by name.
    pub fn findSprite(self: *const TextureManager, sprite_name: []const u8) ?FindSpriteResult {
        var it = self.atlases.valueIterator();
        while (it.next()) |atlas| {
            if (atlas.get(sprite_name)) |data| {
                return .{
                    .sprite = data,
                    .texture_id = atlas.texture_id,
                    .texture_scale_x = atlas.texture_scale_x,
                    .texture_scale_y = atlas.texture_scale_y,
                };
            }
        }
        return null;
    }

    /// Remove an existing atlas if present (used before replacing with a new one).
    fn removeExisting(self: *TextureManager, name: []const u8) void {
        if (self.atlases.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            var atlas = kv.value;
            atlas.deinit();
        }
    }

    /// Remove an atlas by name, freeing all associated memory.
    pub fn unloadAtlas(self: *TextureManager, name: []const u8) void {
        if (self.atlases.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            var atlas = kv.value;
            atlas.deinit();
            self.version += 1;
        }
    }

    /// Remove all atlases.
    pub fn unloadAll(self: *TextureManager) void {
        self.freeAllEntries();
        self.atlases.clearRetainingCapacity();
        self.version += 1;
    }

    fn freeAllEntries(self: *TextureManager) void {
        var it = self.atlases.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
    }

    pub fn atlasCount(self: *const TextureManager) usize {
        return self.atlases.count();
    }

    pub fn totalSpriteCount(self: *const TextureManager) usize {
        var total: usize = 0;
        var it = self.atlases.valueIterator();
        while (it.next()) |atlas| {
            total += atlas.count();
        }
        return total;
    }

    pub fn getVersion(self: *const TextureManager) u32 {
        return self.version;
    }
};

/// Per-entity sprite lookup cache with version-based invalidation.
/// Avoids repeated hash map lookups when sprite names and atlases haven't changed.
pub const SpriteCache = struct {
    entries: std.AutoHashMap(u32, CacheEntry),
    allocator: std.mem.Allocator,
    hits: u64 = 0,
    misses: u64 = 0,

    const CacheEntry = struct {
        result: FindSpriteResult,
        atlas_version: u32,
        name_hash: u64,
    };

    pub fn init(allocator: std.mem.Allocator) SpriteCache {
        return .{
            .entries = std.AutoHashMap(u32, CacheEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpriteCache) void {
        self.entries.deinit();
    }

    /// Look up a sprite for an entity, using the cache when possible.
    /// Returns cached result if atlas version and sprite name haven't changed.
    pub fn lookup(
        self: *SpriteCache,
        entity_id: u32,
        sprite_name: []const u8,
        manager: *const TextureManager,
    ) ?FindSpriteResult {
        if (sprite_name.len == 0) return null;

        const current_version = manager.version;
        const name_hash = std.hash.Wyhash.hash(0, sprite_name);

        if (self.entries.get(entity_id)) |cached| {
            if (cached.atlas_version == current_version and cached.name_hash == name_hash) {
                self.hits += 1;
                return cached.result;
            }
        }

        // Cache miss — do the full lookup
        self.misses += 1;
        const result = manager.findSprite(sprite_name) orelse return null;

        self.entries.put(entity_id, .{
            .result = result,
            .atlas_version = current_version,
            .name_hash = name_hash,
        }) catch {};

        return result;
    }

    /// Remove a cached entry (e.g. when entity is destroyed).
    pub fn invalidate(self: *SpriteCache, entity_id: u32) void {
        _ = self.entries.remove(entity_id);
    }

    /// Clear the entire cache (e.g. on scene change).
    pub fn clear(self: *SpriteCache) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn entryCount(self: *const SpriteCache) usize {
        return self.entries.count();
    }
};

// ── JSON Parsing ────────────────────────────────────────────

/// Per-atlas metadata extracted from `meta.size` in the JSON. Optional
/// because not every TexturePacker output includes a `meta` block.
pub const AtlasMeta = struct {
    /// Logical pixel grid the atlas was authored against. When this
    /// differs from the actual texture pixel dims, the loader derives
    /// a `texture_scale` so source-rect coords stay in physical space
    /// while display coords stay at the original resolution.
    logical_width: ?u32 = null,
    logical_height: ?u32 = null,
};

/// Parse a TexturePacker JSON Hash format file into a sprite map.
/// Returns `meta.size` so the caller can derive a texture scale.
fn parseTexturePackerJson(
    allocator: std.mem.Allocator,
    json_path: [:0]const u8,
    sprites: *std.StringHashMap(SpriteData),
) !AtlasMeta {
    const file = try std.fs.cwd().openFile(json_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return parseTexturePackerJsonContent(allocator, content, sprites);
}

/// Parse TexturePacker JSON content (already in memory) into a sprite map.
/// Returns `meta.size` so the caller can derive a texture scale.
fn parseTexturePackerJsonContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    sprites: *std.StringHashMap(SpriteData),
) !AtlasMeta {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const frames_val = root.get("frames") orelse return error.InvalidAtlasFormat;

    switch (frames_val) {
        .object => |frames_obj| try parseFramesObject(allocator, frames_obj, sprites),
        .array => |frames_arr| try parseFramesArray(allocator, frames_arr, sprites),
        else => return error.InvalidAtlasFormat,
    }

    var meta: AtlasMeta = .{};
    if (root.get("meta")) |meta_val| {
        if (meta_val == .object) {
            if (meta_val.object.get("size")) |size_val| {
                if (size_val == .object) {
                    const size_obj = size_val.object;
                    meta.logical_width = jsonInt(u32, size_obj.get("w"));
                    meta.logical_height = jsonInt(u32, size_obj.get("h"));
                }
            }
        }
    }
    return meta;
}

/// Compute and apply the per-axis texture scale by comparing the JSON's
/// logical size against the actual texture's pixel dims. When either is
/// missing or zero the scale stays at `1.0` — preserving legacy
/// behavior for callers that don't track texture dims.
fn applyTextureScale(atlas: *RuntimeAtlas, meta: AtlasMeta, actual_dims: ?TextureManager.TextureDims) void {
    const dims = actual_dims orelse return;
    if (meta.logical_width) |lw| {
        if (lw > 0 and dims.width > 0) {
            atlas.texture_scale_x = @as(f32, @floatFromInt(dims.width)) / @as(f32, @floatFromInt(lw));
        }
    }
    if (meta.logical_height) |lh| {
        if (lh > 0 and dims.height > 0) {
            atlas.texture_scale_y = @as(f32, @floatFromInt(dims.height)) / @as(f32, @floatFromInt(lh));
        }
    }
}

/// Parse frames in JSON Hash format: { "name": { "frame": {...}, ... }, ... }
fn parseFramesObject(
    allocator: std.mem.Allocator,
    frames: std.json.ObjectMap,
    sprites: *std.StringHashMap(SpriteData),
) !void {
    var it = frames.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const val = entry.value_ptr.object;
        const sprite = extractSpriteData(val) orelse continue;

        const owned_name = try allocator.dupe(u8, name);
        if (sprites.fetchPut(owned_name, sprite) catch null) |old| {
            allocator.free(old.key);
        }
    }
}

/// Parse frames in JSON Array format: [ { "filename": "name", "frame": {...}, ... }, ... ]
fn parseFramesArray(
    allocator: std.mem.Allocator,
    frames: std.json.Array,
    sprites: *std.StringHashMap(SpriteData),
) !void {
    for (frames.items) |item| {
        const val = item.object;
        const filename = val.get("filename") orelse continue;
        const name = switch (filename) {
            .string => |s| s,
            else => continue,
        };
        const sprite = extractSpriteData(val) orelse continue;

        const owned_name = try allocator.dupe(u8, name);
        if (sprites.fetchPut(owned_name, sprite) catch null) |old| {
            allocator.free(old.key);
        }
    }
}

/// Extract SpriteData from a single frame's JSON object.
fn extractSpriteData(val: std.json.ObjectMap) ?SpriteData {
    const frame_obj = (val.get("frame") orelse return null).object;
    const rotated = if (val.get("rotated")) |v| v.bool else false;
    const trimmed = if (val.get("trimmed")) |v| v.bool else false;

    var offset_x: i32 = 0;
    var offset_y: i32 = 0;
    if (val.get("spriteSourceSize")) |sss_val| {
        const sss = sss_val.object;
        offset_x = jsonInt(i32, sss.get("x"));
        offset_y = jsonInt(i32, sss.get("y"));
    }

    var source_width: u32 = 0;
    var source_height: u32 = 0;
    if (val.get("sourceSize")) |ss_val| {
        const ss = ss_val.object;
        source_width = jsonInt(u32, ss.get("w"));
        source_height = jsonInt(u32, ss.get("h"));
    }

    return .{
        .x = jsonInt(u32, frame_obj.get("x")),
        .y = jsonInt(u32, frame_obj.get("y")),
        .width = jsonInt(u32, frame_obj.get("w")),
        .height = jsonInt(u32, frame_obj.get("h")),
        .rotated = rotated,
        .trimmed = trimmed,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .source_width = source_width,
        .source_height = source_height,
    };
}

fn jsonInt(comptime T: type, val: ?std.json.Value) T {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
