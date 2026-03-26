/// Runtime JSONC scene bridge — loads JSONC scene files into the ECS.
///
/// Bridges the jsonc subproject's Value tree with the engine's comptime
/// component registry. Components are deserialized at runtime using
/// comptime-generated type dispatch.
///
/// Visual components (Sprite, Shape) are registered with the renderer
/// via game.addSprite() / game.addShape() instead of plain addComponent().
const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;
const core = @import("labelle-core");
const Position = core.Position;

/// Create a JSONC scene loader parameterized by game and component types.
/// Components is a ComponentRegistry/ComponentRegistryWithPlugins type with has/getType/names.
pub fn JsoncSceneBridge(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;

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

            // Load prefab cache (tries .jsonc then .zon)
            var prefab_cache = PrefabCache.init(game.allocator, prefab_dir);

            // Process entities
            if (scene_obj.getArray("entities")) |entities_arr| {
                for (entities_arr.items) |entity_val| {
                    try loadEntity(game, entity_val, &prefab_cache, 0);
                }
            }
        }

        const MAX_DEPTH = 16;

        /// Minimal prefab cache — loads and caches prefab files from disk.
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

                // Try .jsonc first, then .zon
                const extensions = [_][]const u8{ ".jsonc", ".zon" };
                for (extensions) |ext| {
                    const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ self.prefab_dir, name, ext }) catch return null;
                    defer self.allocator.free(path);
                    const file = std.fs.cwd().openFile(path, .{}) catch continue;
                    defer file.close();

                    const src = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return null;
                    // Both JSONC and ZON prefabs use the same structure after the RFC:
                    // { "components": { ... }, "children": [...] }
                    // For .zon files, we still parse with JSONC parser — won't work for ZON syntax.
                    // .zon prefabs must be converted to .jsonc for runtime loading.
                    var p = JsoncParser.init(self.allocator, src);
                    const val = p.parse() catch {
                        self.allocator.free(src);
                        continue;
                    };
                    self.prefabs.put(self.allocator.dupe(u8, name) catch return null, val) catch return null;
                    return val;
                }
                return null;
            }
        };

        fn loadEntity(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize) !void {
            return loadEntityWithOffset(game, entity_val, prefab_cache, depth, .{ .x = 0, .y = 0 });
        }

        fn loadEntityWithOffset(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position) !void {
            if (depth > MAX_DEPTH) return error.IncludeDepthExceeded;
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

            // Build merged component map: prefab defaults, then scene overrides
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            // Apply scene components (these override prefab defaults)
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    applyComponent(game, entity, entry.key, entry.value, parent_offset);
                    applied.put(entry.key, {}) catch {};
                }
            }

            // Apply prefab components (skip if already overridden by scene)
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        applyComponent(game, entity, entry.key, entry.value, parent_offset);
                    }
                }
            }

            // Get this entity's world position for offsetting nested children
            const entity_pos = game.getPosition(entity);

            // Spawn nested entity arrays from applied components (scene overrides first)
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    spawnNestedEntities(game, entry.value, entity_pos, prefab_cache, depth);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnNestedEntities(game, entry.value, entity_pos, prefab_cache, depth);
                    }
                }
            }

            // Process prefab children
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    try loadEntity(game, child_val, prefab_cache, depth + 1);
                }
            }

            // Process entity-level children
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    try loadEntity(game, child_val, prefab_cache, depth + 1);
                }
            }
        }

        /// Detect and spawn entity-like objects nested inside component values.
        /// Scans object fields for arrays containing objects with "prefab" or "components" keys.
        /// This handles domain-specific patterns like Room.workstations, Room.movement_nodes,
        /// Workstation.storages, ShipCarcase.movement_nodes.
        fn spawnNestedEntities(game: *GameType, comp_value: Value, parent_world_pos: Position, prefab_cache: *PrefabCache, depth: usize) void {
            const obj = comp_value.asObject() orelse return;
            for (obj.entries) |entry| {
                if (entry.value.asArray()) |arr| {
                    for (arr.items) |item| {
                        if (isEntityLike(item)) {
                            loadEntityWithOffset(game, item, prefab_cache, depth + 1, parent_world_pos) catch {};
                        }
                    }
                }
            }
        }

        /// Check if a Value looks like an entity definition (has "prefab" or "components" key).
        fn isEntityLike(value: Value) bool {
            const obj = value.asObject() orelse return false;
            return obj.getString("prefab") != null or obj.getObject("components") != null;
        }

        /// Apply a single named component to an entity.
        /// Handles visual components (Sprite, Shape) specially via renderer registration.
        /// Uses comptime dispatch over the Components registry for everything else.
        fn applyComponent(game: *GameType, entity: Entity, name: []const u8, value: Value, parent_offset: Position) void {
            // Position — uses setPosition, offset by parent position
            if (std.mem.eql(u8, name, "Position")) {
                if (value.asObject()) |obj| {
                    var pos = Position{};
                    if (obj.getInteger("x")) |x| pos.x = @floatFromInt(x);
                    if (obj.getFloat("x")) |x| pos.x = @floatCast(x);
                    if (obj.getInteger("y")) |y| pos.y = @floatFromInt(y);
                    if (obj.getFloat("y")) |y| pos.y = @floatCast(y);
                    game.setPosition(entity, .{ .x = parent_offset.x + pos.x, .y = parent_offset.y + pos.y });
                }
                return;
            }

            // Sprite — uses addSprite for renderer registration
            if (std.mem.eql(u8, name, "Sprite")) {
                if (jsonc.deserialize(Sprite, value, game.allocator)) |sprite| {
                    game.addSprite(entity, sprite);
                } else |_| {}
                return;
            }

            // Shape — uses addShape for renderer registration
            if (std.mem.eql(u8, name, "Shape")) {
                if (jsonc.deserialize(Shape, value, game.allocator)) |shape| {
                    game.addShape(entity, shape);
                } else |_| {}
                return;
            }

            // All other components — comptime dispatch via Components registry
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
