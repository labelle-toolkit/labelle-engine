/// Runtime JSONC scene bridge — loads JSONC scene files into the ECS.
///
/// Bridges the jsonc subproject's Value tree with the engine's comptime
/// component registry. Components are deserialized at runtime using
/// comptime-generated type dispatch.
const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;
const core = @import("labelle-core");
const Position = core.Position;

/// Create a JSONC scene loader parameterized by game and component types.
/// Components is a ComponentRegistry/ComponentRegistryWithPlugins type with has/getType/names.
pub fn JsoncSceneBridge(comptime GameType: type, comptime Components: type) type {
    return struct {
        /// Load a JSONC scene file and instantiate all entities in the ECS.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            const file = try std.fs.cwd().openFile(scene_path, .{});
            defer file.close();
            const source = try file.readToEndAlloc(game.allocator, 1024 * 1024);
            defer game.allocator.free(source);

            var parser = JsoncParser.init(game.allocator, source);
            const scene_value = try parser.parse();

            const scene_obj = scene_value.asObject() orelse return;

            // Load prefab cache
            var prefab_cache = PrefabCache.init(game.allocator, prefab_dir);

            // Process entities
            if (scene_obj.getArray("entities")) |entities_arr| {
                for (entities_arr.items) |entity_val| {
                    try loadEntity(game, entity_val, &prefab_cache);
                }
            }
        }

        /// Minimal prefab cache — loads and caches prefab JSONC files.
        const PrefabCache = struct {
            prefabs: std.StringHashMap(Value),
            allocator: std.mem.Allocator,
            prefab_dir: []const u8,

            fn init(allocator: std.mem.Allocator, prefab_dir: []const u8) PrefabCache {
                return .{
                    .prefabs = std.StringHashMap(Value).init(allocator),
                    .allocator = allocator,
                    .prefab_dir = prefab_dir,
                };
            }

            fn get(self: *PrefabCache, name: []const u8) ?Value {
                if (self.prefabs.get(name)) |val| return val;

                const path = std.fmt.allocPrint(self.allocator, "{s}/{s}.jsonc", .{ self.prefab_dir, name }) catch return null;
                defer self.allocator.free(path);
                const file = std.fs.cwd().openFile(path, .{}) catch return null;
                defer file.close();

                const src = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return null;
                var p = JsoncParser.init(self.allocator, src);
                const val = p.parse() catch return null;
                self.prefabs.put(self.allocator.dupe(u8, name) catch return null, val) catch return null;
                return val;
            }
        };

        fn loadEntity(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache) !void {
            const entity_obj = entity_val.asObject() orelse return;

            // Resolve prefab
            var prefab_components: ?Value.Object = null;
            var prefab_children: ?Value.Array = null;
            if (entity_obj.getString("prefab")) |prefab_name| {
                if (prefab_cache.get(prefab_name)) |prefab_val| {
                    if (prefab_val.asObject()) |prefab_obj| {
                        prefab_components = prefab_obj.getObject("components");
                        prefab_children = prefab_obj.getArray("children");
                    }
                }
            }

            const scene_components = entity_obj.getObject("components");

            // Create entity
            const entity = game.createEntity();

            // Apply prefab components first
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    applyComponent(game, entity, entry.key, entry.value);
                }
            }

            // Apply scene component overrides
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    applyComponent(game, entity, entry.key, entry.value);
                }
            }

            // Process prefab children
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    try loadEntity(game, child_val, prefab_cache);
                }
            }

            // Process entity-level children
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    try loadEntity(game, child_val, prefab_cache);
                }
            }
        }

        /// Apply a single named component to an entity.
        /// Uses comptime dispatch over the Components registry.
        fn applyComponent(game: *GameType, entity: GameType.EntityType, name: []const u8, value: Value) void {
            // Handle Position specially
            if (std.mem.eql(u8, name, "Position")) {
                if (value.asObject()) |obj| {
                    var pos = Position{};
                    if (obj.getInteger("x")) |x| pos.x = @floatFromInt(x);
                    if (obj.getFloat("x")) |x| pos.x = @floatCast(x);
                    if (obj.getInteger("y")) |y| pos.y = @floatFromInt(y);
                    if (obj.getFloat("y")) |y| pos.y = @floatCast(y);
                    game.setPosition(entity, pos);
                }
                return;
            }

            // Dispatch to registered components via comptime unrolled switch
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (jsonc.deserialize(T, value, game.allocator)) |component| {
                        game.addComponent(entity, component);
                    } else |_| {
                        // Deserialization failed — skip this component
                    }
                    return;
                }
            }
            // Unknown component — silently skip
        }
    };
}
