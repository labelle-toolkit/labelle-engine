const std = @import("std");
const jsonc_parser = @import("parser.zig");
const Value = @import("value.zig").Value;
const Allocator = std.mem.Allocator;

/// A runtime-loaded scene with entities, scripts, and metadata.
pub const Scene = struct {
    name: []const u8,
    scripts: []const []const u8,
    entities: []const Entity,
    camera: ?CameraConfig,
    allocator: Allocator,

    pub const CameraConfig = struct {
        x: f32 = 0,
        y: f32 = 0,
        zoom: f32 = 1,
    };

    pub fn getEntitiesByPrefab(self: Scene, prefab_name: []const u8) []const Entity {
        var count: usize = 0;
        for (self.entities) |e| {
            if (e.prefab) |p| {
                if (std.mem.eql(u8, p, prefab_name)) count += 1;
            }
        }
        if (count == 0) return &.{};

        const result = self.allocator.alloc(Entity, count) catch return &.{};
        var i: usize = 0;
        for (self.entities) |e| {
            if (e.prefab) |p| {
                if (std.mem.eql(u8, p, prefab_name)) {
                    result[i] = e;
                    i += 1;
                }
            }
        }
        return result;
    }
};

/// A runtime entity with its parsed component data (not yet deserialized to concrete types).
pub const Entity = struct {
    prefab: ?[]const u8,
    components: []const ComponentData,
    children: []const Entity,
    parent_index: ?usize, // index into scene.entities of parent, set during flattening
    children_indices: []const usize, // indices into scene.entities of children, set during flattening

    pub const ComponentData = struct {
        name: []const u8,
        value: Value,
    };

    pub fn getComponent(self: Entity, name: []const u8) ?Value {
        for (self.components) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    pub fn hasComponent(self: Entity, name: []const u8) bool {
        return self.getComponent(name) != null;
    }

    pub fn hasChildren(self: Entity) bool {
        return self.children.len > 0;
    }
};

/// Prefab cache — loads and caches prefab files from a directory.
pub const PrefabCache = struct {
    prefabs: std.StringHashMap(Value),
    allocator: Allocator,
    prefab_dir: []const u8,

    pub fn init(allocator: Allocator, prefab_dir: []const u8) PrefabCache {
        return .{
            .prefabs = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .prefab_dir = prefab_dir,
        };
    }

    /// Get a prefab by name, loading from disk if not cached.
    pub fn get(self: *PrefabCache, name: []const u8) !?Value {
        if (self.prefabs.get(name)) |val| return val;

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.jsonc", .{ self.prefab_dir, name });
        defer self.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return error.FileNotFound; // propagate as LoadError
        };
        defer file.close();

        const source = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(source);
        var p = jsonc_parser.JsoncParser.init(self.allocator, source);
        const val = try p.parse();

        try self.prefabs.put(try self.allocator.dupe(u8, name), val);
        return val;
    }

    /// Manually insert a prefab (for testing).
    pub fn put(self: *PrefabCache, name: []const u8, val: Value) !void {
        try self.prefabs.put(try self.allocator.dupe(u8, name), val);
    }
};

pub const LoadError = error{
    InvalidScene,
    InvalidEntity,
    InvalidPrefab,
    IncludeDepthExceeded,
    OutOfMemory,
    ParseError,
} || std.fs.File.OpenError || std.fs.File.ReadError || jsonc_parser.ParseError;

const MAX_INCLUDE_DEPTH = 16;
const MAX_ENTITY_DEPTH = 16;

/// Load a scene from a file path, resolving prefabs and includes.
pub fn loadScene(allocator: Allocator, scene_path: []const u8, prefab_dir: []const u8) LoadError!Scene {
    const file = try std.fs.cwd().openFile(scene_path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);
    var p = jsonc_parser.JsoncParser.init(allocator, source);
    const scene_value = try p.parse();

    // Resolve base_dir from scene_path for relative includes
    const base_dir = std.fs.path.dirname(scene_path) orelse ".";

    return loadSceneFromValue(allocator, scene_value, prefab_dir, base_dir);
}

/// Load a scene from an already-parsed Value.
pub fn loadSceneFromValue(
    allocator: Allocator,
    scene_value: Value,
    prefab_dir: []const u8,
    base_dir: []const u8,
) LoadError!Scene {
    var prefab_cache = PrefabCache.init(allocator, prefab_dir);
    return loadSceneInner(allocator, scene_value, &prefab_cache, base_dir, 0);
}

pub fn loadSceneInner(
    allocator: Allocator,
    scene_value: Value,
    prefab_cache: *PrefabCache,
    base_dir: []const u8,
    depth: usize,
) LoadError!Scene {
    if (depth > MAX_INCLUDE_DEPTH) return error.IncludeDepthExceeded;

    const scene_obj = scene_value.asObject() orelse return error.InvalidScene;

    const name = scene_obj.getString("name") orelse "unnamed";

    // Scripts
    var scripts: []const []const u8 = &.{};
    if (scene_obj.getArray("scripts")) |scripts_arr| {
        var script_list: std.ArrayList([]const u8) = .{};
        errdefer script_list.deinit(allocator);
        for (scripts_arr.items) |item| {
            if (item.asString()) |s| {
                try script_list.append(allocator, s);
            }
        }
        scripts = try script_list.toOwnedSlice(allocator);
    }

    // Camera
    var camera: ?Scene.CameraConfig = null;
    if (scene_obj.getObject("camera")) |cam_obj| {
        camera = .{};
        if (cam_obj.getInteger("x")) |x| camera.?.x = @floatFromInt(x);
        if (cam_obj.getFloat("x")) |x| camera.?.x = @floatCast(x);
        if (cam_obj.getInteger("y")) |y| camera.?.y = @floatFromInt(y);
        if (cam_obj.getFloat("y")) |y| camera.?.y = @floatCast(y);
        if (cam_obj.getFloat("zoom")) |z| camera.?.zoom = @floatCast(z);
        if (cam_obj.getInteger("zoom")) |z| camera.?.zoom = @floatFromInt(z);
    }

    var entities: std.ArrayList(Entity) = .{};
    errdefer entities.deinit(allocator);

    // Process includes first — included entities come before local entities
    if (scene_obj.getArray("include")) |include_arr| {
        for (include_arr.items) |include_val| {
            if (include_val.asString()) |include_path| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, include_path });
                defer allocator.free(full_path);
                const included = loadInclude(allocator, full_path, prefab_cache, depth + 1) catch |err| {
                    if (err == error.FileNotFound) continue; // skip missing includes gracefully
                    return err;
                };
                defer allocator.free(included);
                for (included) |e| {
                    try entities.append(allocator, e);
                }
            }
        }
    }

    // Process local entities
    if (scene_obj.getArray("entities")) |entities_arr| {
        for (entities_arr.items) |entity_val| {
            const entity = try loadEntity(allocator, entity_val, prefab_cache);
            try entities.append(allocator, entity);
        }
    }

    return Scene{
        .name = name,
        .scripts = scripts,
        .entities = try entities.toOwnedSlice(allocator),
        .camera = camera,
        .allocator = allocator,
    };
}

/// Load an include file (scene fragment). Returns just the entities.
fn loadInclude(
    allocator: Allocator,
    path: []const u8,
    prefab_cache: *PrefabCache,
    depth: usize,
) LoadError![]const Entity {
    if (depth > MAX_INCLUDE_DEPTH) return error.IncludeDepthExceeded;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| return err;
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);
    var p = jsonc_parser.JsoncParser.init(allocator, source);
    const val = try p.parse();
    const obj = val.asObject() orelse return error.InvalidScene;

    const inc_base_dir = std.fs.path.dirname(path) orelse ".";

    var entities: std.ArrayList(Entity) = .{};
    errdefer entities.deinit(allocator);

    // Nested includes
    if (obj.getArray("include")) |include_arr| {
        for (include_arr.items) |include_val| {
            if (include_val.asString()) |include_path| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ inc_base_dir, include_path });
                defer allocator.free(full_path);
                const included = loadInclude(allocator, full_path, prefab_cache, depth + 1) catch |err| {
                    if (err == error.FileNotFound) continue;
                    return err;
                };
                defer allocator.free(included);
                for (included) |e| {
                    try entities.append(allocator, e);
                }
            }
        }
    }

    // Entities in the fragment
    if (obj.getArray("entities")) |entities_arr| {
        for (entities_arr.items) |entity_val| {
            const entity = try loadEntity(allocator, entity_val, prefab_cache);
            try entities.append(allocator, entity);
        }
    }

    return try entities.toOwnedSlice(allocator);
}

/// Load a single entity, merging with prefab if specified.
/// Prefabs can define children, which become child entities.
/// Depth is capped at MAX_ENTITY_DEPTH to prevent infinite recursion from self-referencing prefabs.
pub fn loadEntity(allocator: Allocator, entity_val: Value, prefab_cache: *PrefabCache) LoadError!Entity {
    return loadEntityInner(allocator, entity_val, prefab_cache, 0);
}

fn loadEntityInner(allocator: Allocator, entity_val: Value, prefab_cache: *PrefabCache, depth: usize) LoadError!Entity {
    if (depth > MAX_ENTITY_DEPTH) return error.IncludeDepthExceeded;
    const entity_obj = entity_val.asObject() orelse return error.InvalidEntity;

    const prefab_name = entity_obj.getString("prefab");
    const scene_components = entity_obj.getObject("components");

    // Load prefab data
    var prefab_components: ?Value.Object = null;
    var prefab_children: ?Value.Array = null;
    if (prefab_name) |pname| {
        if (try prefab_cache.get(pname)) |prefab_val| {
            if (prefab_val.asObject()) |prefab_obj| {
                prefab_components = prefab_obj.getObject("components");
                prefab_children = prefab_obj.getArray("children");
            }
        }
    }

    // Merge components: prefab first, scene overrides
    var merged: std.ArrayList(Entity.ComponentData) = .{};
    errdefer merged.deinit(allocator);

    if (prefab_components) |pc| {
        for (pc.entries) |entry| {
            try merged.append(allocator, .{ .name = entry.key, .value = entry.value });
        }
    }

    if (scene_components) |sc| {
        for (sc.entries) |entry| {
            var found = false;
            for (merged.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing.name, entry.key)) {
                    merged.items[i].value = entry.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try merged.append(allocator, .{ .name = entry.key, .value = entry.value });
            }
        }
    }

    // Collect children: from prefab + from entity definition
    var children: std.ArrayList(Entity) = .{};
    errdefer children.deinit(allocator);

    // Prefab children
    if (prefab_children) |pc| {
        for (pc.items) |child_val| {
            const child = try loadEntityInner(allocator, child_val, prefab_cache, depth + 1);
            try children.append(allocator, child);
        }
    }

    // Entity-level children (extend prefab children)
    if (entity_obj.getArray("children")) |entity_children| {
        for (entity_children.items) |child_val| {
            const child = try loadEntityInner(allocator, child_val, prefab_cache, depth + 1);
            try children.append(allocator, child);
        }
    }

    return Entity{
        .prefab = prefab_name,
        .components = try merged.toOwnedSlice(allocator),
        .children = try children.toOwnedSlice(allocator),
        .parent_index = null,
        .children_indices = &.{},
    };
}

/// Flatten the entity tree into a linear list with bidirectional parent/child indices.
/// Top-level entities come first, then their children depth-first.
/// Sets `parent_index` and `children_indices` on each entity.
pub fn flattenEntities(allocator: Allocator, tree_entities: []const Entity) ![]Entity {
    var flat: std.ArrayList(Entity) = .{};

    // First pass: add all top-level entities to get their indices
    for (tree_entities) |entity| {
        try flattenRecursive(allocator, &flat, entity, null);
    }

    var result = try flat.toOwnedSlice(allocator);

    // Second pass: set children_indices for each entity that has children
    for (result, 0..) |*entity, i| {
        if (entity.children.len > 0) {
            var indices: std.ArrayList(usize) = .{};
            for (result[i + 1 ..], i + 1..) |other, j| {
                if (other.parent_index) |pi| {
                    if (pi == i) try indices.append(allocator, j);
                }
            }
            entity.children_indices = try indices.toOwnedSlice(allocator);
        }
    }

    return result;
}

fn flattenRecursive(
    allocator: Allocator,
    flat: *std.ArrayList(Entity),
    entity: Entity,
    parent_idx: ?usize,
) !void {
    const my_index = flat.items.len;
    var e = entity;
    e.parent_index = parent_idx;
    try flat.append(allocator, e);

    for (entity.children) |child| {
        try flattenRecursive(allocator, flat, child, my_index);
    }
}
