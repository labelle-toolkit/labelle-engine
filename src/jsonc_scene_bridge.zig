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
const scene_mod = @import("scene");
const gizmo_mod = scene_mod.gizmo;

/// Create a JSONC scene loader parameterized by game and component types.
/// Components is a ComponentRegistry/ComponentRegistryWithPlugins type with has/getType/names.
pub fn JsoncSceneBridge(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;

    return struct {
        /// Allocate a persistent PrefabCache and store it on the game for reuse.
        fn initPersistentCache(game: *GameType, prefab_dir: []const u8) !*PrefabCache {
            const persistent = std.heap.page_allocator;
            const cache = try persistent.create(PrefabCache);
            cache.* = PrefabCache.init(game.allocator, prefab_dir);
            game.prefab_cache_ptr = cache;
            return cache;
        }

        /// Load a JSONC scene file and instantiate all entities in the ECS.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            // Load prefab cache (tries .jsonc then .zon)
            const prefab_cache = try initPersistentCache(game, prefab_dir);

            try loadSceneFile(game, scene_path, prefab_cache, 0);

            // Enable runtime prefab spawning
            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Load a scene from an in-memory JSONC source string (for embedded/release builds).
        /// The source must outlive the loaded scene — typically a comptime `@embedFile` slice.
        pub fn loadSceneFromSource(game: *GameType, source: []const u8, prefab_dir: []const u8) !void {
            const prefab_cache = try initPersistentCache(game, prefab_dir);

            try loadSceneSource(game, source, prefab_cache);

            // Enable runtime prefab spawning
            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Runtime prefab instantiation — creates an entity from a named prefab.
        fn spawnPrefabImpl(game: *GameType, name: []const u8, pos: Position) ?Entity {
            const cache_ptr = game.prefab_cache_ptr orelse return null;
            var prefab_cache = @as(*PrefabCache, @ptrCast(@alignCast(cache_ptr)));
            const prefab_val = prefab_cache.get(name) orelse {
                const prefab_dir = game.prefab_dir orelse "?";
                game.log.err("[spawnPrefab] Prefab '{s}' not found in '{s}'", .{ name, prefab_dir });
                return null;
            };
            const prefab_obj = prefab_val.asObject() orelse return null;
            const prefab_components = prefab_obj.getObject("components") orelse return null;

            const entity = game.createEntity();
            game.setPosition(entity, pos);

            // Apply all prefab components — use pos as parent_offset so
            // prefab positions are relative to the spawn point.
            for (prefab_components.entries) |entry| {
                applyComponent(game, entity, entry.key, entry.value, pos);
            }

            // Handle nested entities (e.g. workstation storages)
            const entity_pos = game.getPosition(entity);
            for (prefab_components.entries) |entry| {
                spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, 0);
            }

            // Fire onReady hooks
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();
            fireOnReadyAll(game, entity, null, prefab_components, &applied);

            // Process children
            if (prefab_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    const child = spawnChildEntity(game, child_val, prefab_cache, 1, entity_pos) catch continue;
                    game.setParent(child, entity, .{});
                }
            }

            return entity;
        }

        // ================================================================
        // Entity cross-references (@ref syntax)
        // ================================================================

        /// A component whose entity_ref fields contain @ref strings.
        /// Deferred to pass 2 for resolution after all entities are created.
        const DeferredRef = struct {
            entity: Entity,
            comp_name: []const u8,
            value: Value,
            parent_offset: Position,
        };

        /// Ref context shared across entity loading — collects named refs
        /// and deferred components for two-pass resolution.
        const RefContext = struct {
            ref_map: std.StringHashMap(u64),
            deferred: std.ArrayListUnmanaged(DeferredRef),
            allocator: std.mem.Allocator,

            fn init(allocator: std.mem.Allocator) RefContext {
                return .{
                    .ref_map = std.StringHashMap(u64).init(allocator),
                    .deferred = .{},
                    .allocator = allocator,
                };
            }

            fn deinit(self: *RefContext) void {
                self.ref_map.deinit();
                self.deferred.deinit(self.allocator);
            }
        };

        /// Check if a component value contains @ref strings in entity_ref fields.
        fn valueHasRefs(comp_name: []const u8, value: Value) bool {
            const obj = value.asObject() orelse return false;
            const comp_names = comptime Components.names();
            inline for (comp_names) |name| {
                if (std.mem.eql(u8, comp_name, name)) {
                    return hasRefsInFields(Components.getType(name), obj);
                }
            }
            return false;
        }

        fn hasRefsInFields(comptime T: type, obj: Value.Object) bool {
            const ref_fields = comptime core.getEntityRefFields(T);
            inline for (ref_fields) |field_name| {
                if (obj.getString(field_name)) |str| {
                    if (str.len > 0 and str[0] == '@') return true;
                }
            }
            return false;
        }

        /// Resolve a single @ref component: replace @name strings with entity IDs and apply.
        fn resolveRefComponent(game: *GameType, deferred: DeferredRef, ref_map: *const std.StringHashMap(u64)) void {
            const comp_name = deferred.comp_name;
            const obj = deferred.value.asObject() orelse return;
            const comp_names = comptime Components.names();

            inline for (comp_names) |name| {
                if (std.mem.eql(u8, comp_name, name)) {
                    const T = Components.getType(name);
                    resolveAndApply(T, game, deferred.entity, obj, deferred.value, ref_map);
                    return;
                }
            }
        }

        /// Type-specific ref resolution — called with comptime-known T.
        /// Builds a filtered Value with @ref strings replaced by 0 so the
        /// deserializer can parse the component, then patches resolved IDs.
        fn resolveAndApply(comptime T: type, game: *GameType, entity: Entity, obj: Value.Object, value: Value, ref_map: *const std.StringHashMap(u64)) void {
            _ = value;
            // Build filtered entries: replace @ref strings with integer 0
            // so the deserializer doesn't choke on strings in u64 fields.
            const ref_fields = comptime core.getEntityRefFields(T);
            var filtered_buf: [64]Value.Object.Entry = undefined;
            var filtered_len: usize = 0;
            for (obj.entries) |entry| {
                if (filtered_len >= filtered_buf.len) break;
                var e = entry;
                inline for (ref_fields) |field_name| {
                    if (std.mem.eql(u8, entry.key, field_name)) {
                        if (entry.value.asString()) |str| {
                            if (str.len > 0 and str[0] == '@') {
                                e.value = .{ .integer = 0 };
                            }
                        }
                    }
                }
                filtered_buf[filtered_len] = e;
                filtered_len += 1;
            }

            const filtered_value = Value{ .object = .{ .entries = filtered_buf[0..filtered_len] } };
            var component = deserialize(T, filtered_value, game.allocator) orelse return;

            // Patch entity_ref fields with resolved @ref IDs
            inline for (ref_fields) |field_name| {
                if (obj.getString(field_name)) |str| {
                    if (str.len > 0 and str[0] == '@') {
                        const ref_name = str[1..];
                        if (ref_map.get(ref_name)) |resolved_id| {
                            @field(component, field_name) = resolved_id;
                        } else {
                            game.log.err("[SceneRef] Unresolved ref '@{s}' in {s}", .{ ref_name, field_name });
                        }
                    }
                }
            }

            game.addComponent(entity, component);
        }

        /// Process entities from a parsed scene, with two-pass ref resolution.
        fn processEntities(game: *GameType, entities_arr: Value.Array, prefab_cache: *PrefabCache, ref_ctx: *RefContext) LoadEntityError!void {
            // Pass 1: create entities, collect refs, defer @ref components
            for (entities_arr.items) |entity_val| {
                try loadEntityWithRefs(game, entity_val, prefab_cache, 0, .{ .x = 0, .y = 0 }, ref_ctx);
            }

            // Pass 2: resolve deferred @ref components
            for (ref_ctx.deferred.items) |deferred| {
                resolveRefComponent(game, deferred, &ref_ctx.ref_map);
            }
        }

        /// Load a single scene/fragment file, processing includes recursively then its own entities.
        fn loadSceneFile(game: *GameType, path: []const u8, prefab_cache: *PrefabCache, include_depth: usize) !void {
            if (include_depth > MAX_DEPTH) return error.IncludeDepthExceeded;

            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            // Use an arena for the scene parser — the source buffer and parsed
            // Value tree (entries/items slices) are only needed during entity
            // processing and can be freed together afterwards.
            var parse_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer parse_arena.deinit();
            const parse_alloc = parse_arena.allocator();

            const source = try file.readToEndAlloc(parse_alloc, 1024 * 1024);
            var parser = JsoncParser.init(parse_alloc, source);
            const scene_value = try parser.parse();

            const scene_obj = scene_value.asObject() orelse return;

            // Process includes first — their entities are created before this file's own entities
            if (scene_obj.getArray("include")) |include_arr| {
                for (include_arr.items) |include_val| {
                    const include_path = include_val.asString() orelse continue;
                    try loadSceneFile(game, include_path, prefab_cache, include_depth + 1);
                }
            }

            // Process this file's entities with ref support
            if (scene_obj.getArray("entities")) |entities_arr| {
                var ref_ctx = RefContext.init(game.allocator);
                defer ref_ctx.deinit();
                try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
            }
        }

        /// Load a scene from an in-memory source string (no file I/O).
        /// Includes still load from disk if present in the scene.
        /// Note: duplicates parse/entity logic from loadSceneFile because Zig cannot
        /// resolve inferred error sets with mutual recursion (processScene <-> loadSceneFile).
        fn loadSceneSource(game: *GameType, source: []const u8, prefab_cache: *PrefabCache) !void {
            var parse_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer parse_arena.deinit();
            const parse_alloc = parse_arena.allocator();

            var parser = JsoncParser.init(parse_alloc, source);
            const scene_value = try parser.parse();

            const scene_obj = scene_value.asObject() orelse return;

            if (scene_obj.getArray("include")) |include_arr| {
                for (include_arr.items) |include_val| {
                    const include_path = include_val.asString() orelse continue;
                    try loadSceneFile(game, include_path, prefab_cache, 1);
                }
            }

            if (scene_obj.getArray("entities")) |entities_arr| {
                var ref_ctx = RefContext.init(game.allocator);
                defer ref_ctx.deinit();
                try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
            }
        }

        const MAX_DEPTH = 16;

        /// Minimal prefab cache — loads and caches prefab files from disk.
        /// Source buffers and parsed Value trees are game-lifetime data — deserialized
        /// components hold []const u8 slices referencing them. Uses page_allocator for
        /// persistent data so the GPA doesn't report them as leaks.
        const PrefabCache = struct {
            prefabs: std.StringHashMap(Value),
            persistent: std.mem.Allocator,
            temp: std.mem.Allocator,
            prefab_dir: []const u8,

            fn init(allocator: std.mem.Allocator, prefab_dir: []const u8) PrefabCache {
                const persistent = std.heap.page_allocator;
                return .{
                    .prefabs = std.StringHashMap(Value).init(persistent),
                    .persistent = persistent,
                    .temp = allocator,
                    .prefab_dir = prefab_dir,
                };
            }

            fn get(self: *PrefabCache, name: []const u8) ?Value {
                if (self.prefabs.get(name)) |val| return val;

                const path = std.fmt.allocPrint(self.temp, "{s}/{s}.jsonc", .{ self.prefab_dir, name }) catch return null;
                defer self.temp.free(path);
                const file = std.fs.cwd().openFile(path, .{}) catch return null;
                defer file.close();

                const src = file.readToEndAlloc(self.persistent, 1024 * 1024) catch return null;
                var p = JsoncParser.init(self.persistent, src);
                const val = p.parse() catch return null;
                self.prefabs.put(self.persistent.dupe(u8, name) catch return null, val) catch return null;
                return val;
            }
        };

        const LoadEntityError = error{ IncludeDepthExceeded, OutOfMemory };

        fn loadEntity(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize) LoadEntityError!void {
            return loadEntityWithOffset(game, entity_val, prefab_cache, depth, .{ .x = 0, .y = 0 });
        }

        /// Load entity with ref support — collects "ref" names and defers @ref components.
        fn loadEntityWithRefs(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position, ref_ctx: *RefContext) LoadEntityError!void {
            if (depth > MAX_DEPTH) return error.IncludeDepthExceeded;
            const entity_obj = entity_val.asObject() orelse return;

            // Resolve prefab
            var prefab_components: ?Value.Object = null;
            var prefab_children: ?Value.Array = null;
            var prefab_obj: ?Value.Object = null;
            if (entity_obj.getString("prefab")) |prefab_name| {
                if (prefab_cache.get(prefab_name)) |prefab_val| {
                    if (prefab_val.asObject()) |pobj| {
                        prefab_obj = pobj;
                        prefab_components = pobj.getObject("components");
                        prefab_children = pobj.getArray("children");
                    }
                }
            }

            const scene_components = entity_obj.getObject("components");

            // Create entity
            const entity = game.createEntity();
            const entity_id: u64 = @intCast(entity);

            // Register ref name — scene-level ref overrides prefab-level ref
            if (entity_obj.getString("ref")) |ref_name| {
                ref_ctx.ref_map.put(ref_name, entity_id) catch {};
            } else if (prefab_obj) |pobj| {
                if (pobj.getString("ref")) |ref_name| {
                    ref_ctx.ref_map.put(ref_name, entity_id) catch {};
                }
            }

            // Build merged component map: prefab defaults, then scene overrides
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            // Apply scene components (these override prefab defaults)
            // Defer components with @ref values
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    if (valueHasRefs(entry.key, entry.value)) {
                        ref_ctx.deferred.append(ref_ctx.allocator, .{
                            .entity = entity,
                            .comp_name = entry.key,
                            .value = entry.value,
                            .parent_offset = parent_offset,
                        }) catch {};
                    } else {
                        applyComponent(game, entity, entry.key, entry.value, parent_offset);
                    }
                    applied.put(entry.key, {}) catch {};
                }
            }

            // Apply prefab components (skip if overridden; defer if has @ref)
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        if (valueHasRefs(entry.key, entry.value)) {
                            ref_ctx.deferred.append(ref_ctx.allocator, .{
                                .entity = entity,
                                .comp_name = entry.key,
                                .value = entry.value,
                                .parent_offset = parent_offset,
                            }) catch {};
                        } else {
                            applyComponent(game, entity, entry.key, entry.value, parent_offset);
                        }
                    }
                }
            }

            // Get this entity's world position for offsetting nested children
            const entity_pos = game.getPosition(entity);

            // Spawn nested entity arrays and collect IDs
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth);
                    }
                }
            }

            // Fire onReady for all applied components
            fireOnReadyAll(game, entity, scene_components, prefab_components, &applied);

            // Process prefab children (with ref support)
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    const child = try spawnChildEntityWithRefs(game, child_val, prefab_cache, depth + 1, entity_pos, ref_ctx);
                    game.setParent(child, entity, .{});
                }
            }

            // Process entity-level children (with ref support)
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    const child = try spawnChildEntityWithRefs(game, child_val, prefab_cache, depth + 1, entity_pos, ref_ctx);
                    game.setParent(child, entity, .{});
                }
            }
        }

        /// Spawn a child entity with ref context support.
        fn spawnChildEntityWithRefs(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_pos: Position, ref_ctx: *RefContext) LoadEntityError!Entity {
            const entity_obj = entity_val.asObject() orelse return error.OutOfMemory;

            var child_prefab_comps: ?Value.Object = null;
            var child_prefab_children: ?Value.Array = null;
            if (entity_obj.getString("prefab")) |pname| {
                if (prefab_cache.get(pname)) |pval| {
                    if (pval.asObject()) |pobj| {
                        child_prefab_comps = pobj.getObject("components");
                        child_prefab_children = pobj.getArray("children");
                    }
                }
            }

            const child_scene_comps = entity_obj.getObject("components");
            const child = game.createEntity();
            const child_id: u64 = @intCast(child);

            // Register ref name if present
            if (entity_obj.getString("ref")) |ref_name| {
                ref_ctx.ref_map.put(ref_name, child_id) catch {};
            }

            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            if (child_scene_comps) |sc| {
                for (sc.entries) |entry| {
                    if (valueHasRefs(entry.key, entry.value)) {
                        ref_ctx.deferred.append(ref_ctx.allocator, .{
                            .entity = child,
                            .comp_name = entry.key,
                            .value = entry.value,
                            .parent_offset = parent_pos,
                        }) catch {};
                    } else {
                        applyComponent(game, child, entry.key, entry.value, parent_pos);
                    }
                    applied.put(entry.key, {}) catch {};
                }
            }
            if (child_prefab_comps) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        if (valueHasRefs(entry.key, entry.value)) {
                            ref_ctx.deferred.append(ref_ctx.allocator, .{
                                .entity = child,
                                .comp_name = entry.key,
                                .value = entry.value,
                                .parent_offset = parent_pos,
                            }) catch {};
                        } else {
                            applyComponent(game, child, entry.key, entry.value, parent_pos);
                        }
                    }
                }
            }

            const child_pos = game.getPosition(child);

            if (child_scene_comps) |sc| {
                for (sc.entries) |entry| {
                    spawnAndLinkNestedEntities(game, child, entry.key, entry.value, child_pos, prefab_cache, depth);
                }
            }
            if (child_prefab_comps) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, child, entry.key, entry.value, child_pos, prefab_cache, depth);
                    }
                }
            }

            fireOnReadyAll(game, child, child_scene_comps, child_prefab_comps, &applied);

            // Recursive children with ref support
            if (child_prefab_children) |children| {
                for (children.items) |cv| {
                    const grandchild = spawnChildEntityWithRefs(game, cv, prefab_cache, depth + 1, child_pos, ref_ctx) catch continue;
                    game.setParent(grandchild, child, .{});
                }
            }
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |cv| {
                    const grandchild = spawnChildEntityWithRefs(game, cv, prefab_cache, depth + 1, child_pos, ref_ctx) catch continue;
                    game.setParent(grandchild, child, .{});
                }
            }

            return child;
        }

        fn loadEntityWithOffset(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position) LoadEntityError!void {
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

            // Spawn nested entity arrays and collect IDs to patch back into components.
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth);
                    }
                }
            }

            // Fire onReady for all applied components (after entity is fully assembled)
            fireOnReadyAll(game, entity, scene_components, prefab_components, &applied);

            // Process prefab children (full parent-child relationship)
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    const child = try spawnChildEntity(game, child_val, prefab_cache, depth + 1, entity_pos);
                    game.setParent(child, entity, .{});
                }
            }

            // Process entity-level children (full parent-child relationship)
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    const child = try spawnChildEntity(game, child_val, prefab_cache, depth + 1, entity_pos);
                    game.setParent(child, entity, .{});
                }
            }
        }

        /// Spawn a child entity and return its ID.
        fn spawnChildEntity(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_pos: Position) LoadEntityError!Entity {
            const entity_obj = entity_val.asObject() orelse return error.OutOfMemory;

            var child_prefab_comps: ?Value.Object = null;
            var child_prefab_children: ?Value.Array = null;
            if (entity_obj.getString("prefab")) |pname| {
                if (prefab_cache.get(pname)) |pval| {
                    if (pval.asObject()) |pobj| {
                        child_prefab_comps = pobj.getObject("components");
                        child_prefab_children = pobj.getArray("children");
                    }
                }
            }

            const child_scene_comps = entity_obj.getObject("components");
            const child = game.createEntity();

            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            if (child_scene_comps) |sc| {
                for (sc.entries) |entry| {
                    applyComponent(game, child, entry.key, entry.value, parent_pos);
                    applied.put(entry.key, {}) catch {};
                }
            }
            if (child_prefab_comps) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        applyComponent(game, child, entry.key, entry.value, parent_pos);
                    }
                }
            }

            const child_pos = game.getPosition(child);

            if (child_scene_comps) |sc| {
                for (sc.entries) |entry| {
                    spawnAndLinkNestedEntities(game, child, entry.key, entry.value, child_pos, prefab_cache, depth);
                }
            }
            if (child_prefab_comps) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, child, entry.key, entry.value, child_pos, prefab_cache, depth);
                    }
                }
            }

            fireOnReadyAll(game, child, child_scene_comps, child_prefab_comps, &applied);

            // Recursive children with parent relationship
            if (child_prefab_children) |children| {
                for (children.items) |cv| {
                    const grandchild = spawnChildEntity(game, cv, prefab_cache, depth + 1, child_pos) catch continue;
                    game.setParent(grandchild, child, .{});
                }
            }
            if (entity_obj.getArray("children")) |children| {
                for (children.items) |cv| {
                    const grandchild = spawnChildEntity(game, cv, prefab_cache, depth + 1, child_pos) catch continue;
                    game.setParent(grandchild, child, .{});
                }
            }

            return child;
        }

        /// Spawn entity-like objects nested inside a component's fields, collect their
        /// entity IDs, and patch them back into the component's []const u64 fields.
        fn spawnAndLinkNestedEntities(
            game: *GameType,
            parent_entity: Entity,
            comp_name: []const u8,
            comp_value: Value,
            parent_world_pos: Position,
            prefab_cache: *PrefabCache,
            depth: usize,
        ) void {
            const obj = comp_value.asObject() orelse return;

            for (obj.entries) |entry| {
                const arr = entry.value.asArray() orelse continue;

                // Count entity-like items
                var entity_count: usize = 0;
                for (arr.items) |item| {
                    if (isEntityLike(item)) entity_count += 1;
                }
                if (entity_count == 0) continue;

                // Spawn entities and collect IDs.
                // Uses page_allocator because IDs are stored in component fields
                // ([]const u64) and live for the game's lifetime.
                const ids = std.heap.page_allocator.alloc(u64, entity_count) catch continue;
                var idx: usize = 0;
                for (arr.items) |item| {
                    if (isEntityLike(item)) {
                        const child = game.createEntity();

                        if (item.asObject()) |child_obj| {
                            var child_prefab_comps: ?Value.Object = null;
                            if (child_obj.getString("prefab")) |pname| {
                                if (prefab_cache.get(pname)) |pval| {
                                    if (pval.asObject()) |pobj| {
                                        child_prefab_comps = pobj.getObject("components");
                                    }
                                }
                            }

                            const child_scene_comps = child_obj.getObject("components");

                            // Scene overrides first
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    applyComponent(game, child, e.key, e.value, parent_world_pos);
                                }
                            }
                            // Prefab defaults
                            if (child_prefab_comps) |pc| {
                                for (pc.entries) |e| {
                                    const already_set = if (child_scene_comps) |sc| blk: {
                                        for (sc.entries) |se| {
                                            if (std.mem.eql(u8, se.key, e.key)) break :blk true;
                                        }
                                        break :blk false;
                                    } else false;
                                    if (!already_set) {
                                        applyComponent(game, child, e.key, e.value, parent_world_pos);
                                    }
                                }
                            }

                            // Recursively spawn nested entities inside this child's components
                            const child_pos = game.getPosition(child);
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    spawnAndLinkNestedEntities(game, child, e.key, e.value, child_pos, prefab_cache, depth + 1);
                                }
                            }
                            if (child_prefab_comps) |pc| {
                                for (pc.entries) |e| {
                                    const already_set = if (child_scene_comps) |sc| blk: {
                                        for (sc.entries) |se| {
                                            if (std.mem.eql(u8, se.key, e.key)) break :blk true;
                                        }
                                        break :blk false;
                                    } else false;
                                    if (!already_set) {
                                        spawnAndLinkNestedEntities(game, child, e.key, e.value, child_pos, prefab_cache, depth + 1);
                                    }
                                }
                            }
                        }

                        ids[idx] = @intCast(child);
                        idx += 1;
                    }
                }

                // Patch the entity ID array back into the parent component
                patchEntityIdField(game, parent_entity, comp_name, entry.key, ids);

                // Register nested entities as children for cascade destruction
                const ChildrenComp = core.ChildrenComponent(Entity);
                for (ids) |child_id| {
                    const child_entity: Entity = @intCast(child_id);
                    if (game.ecs_backend.getComponent(parent_entity, ChildrenComp)) |children_comp| {
                        children_comp.addChild(child_entity);
                    } else {
                        var new_children = ChildrenComp{};
                        new_children.addChild(child_entity);
                        game.ecs_backend.addComponent(parent_entity, new_children);
                    }
                }
            }
        }

        /// Patch a []const u64 field on a component with spawned entity IDs.
        fn patchEntityIdField(game: *GameType, entity: Entity, comp_name: []const u8, field_name: []const u8, ids: []const u64) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |cn| {
                if (std.mem.eql(u8, comp_name, cn)) {
                    const T = Components.getType(cn);
                    if (game.ecs_backend.getComponent(entity, T)) |comp| {
                        inline for (@typeInfo(T).@"struct".fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                if (field.type == []const u64) {
                                    @field(comp, field.name) = ids;
                                }
                            }
                        }
                    }
                    return;
                }
            }
        }

        /// Fire onReady for all components that were applied to an entity.
        fn fireOnReadyAll(
            game: *GameType,
            entity: Entity,
            scene_components: ?Value.Object,
            prefab_components: ?Value.Object,
            applied: *std.StringHashMap(void),
        ) void {
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    fireOnReadyByName(game, entity, entry.key);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        fireOnReadyByName(game, entity, entry.key);
                    }
                }
            }
        }

        /// Fire onReady for a single component by name using comptime dispatch.
        fn fireOnReadyByName(game: *GameType, entity: Entity, name: []const u8) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    game.fireOnReady(entity, T);
                    if (@hasDecl(T, "postLoad")) {
                        if (game.ecs_backend.getComponent(entity, T)) |comp| {
                            comp.postLoad(game, entity);
                        }
                    }
                    return;
                }
            }
        }

        /// Strip fields that contain entity-like arrays from a component Value.
        fn stripEntityArrayFields(value: Value, allocator: std.mem.Allocator) Value {
            const obj = value.asObject() orelse return value;
            var filtered: std.ArrayList(Value.Object.Entry) = .{};
            for (obj.entries) |entry| {
                const is_entity_array = blk: {
                    const arr = entry.value.asArray() orelse break :blk false;
                    if (arr.items.len == 0) break :blk false;
                    break :blk isEntityLike(arr.items[0]);
                };
                if (!is_entity_array) {
                    filtered.append(allocator, entry) catch {};
                }
            }
            return Value{ .object = .{ .entries = filtered.toOwnedSlice(allocator) catch obj.entries } };
        }

        /// Check if a Value looks like an entity definition.
        fn isEntityLike(value: Value) bool {
            const obj = value.asObject() orelse return false;
            return obj.getString("prefab") != null or obj.getObject("components") != null;
        }

        // =====================================================================
        // Value → Zig type deserialization (inlined, no external dependency)
        // =====================================================================

        /// Deserialize a Value into a comptime-known Zig type.
        fn deserialize(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
            const info = @typeInfo(T);

            // Primitives
            if (T == f32 or T == f64) return valueToFloat(T, value);
            if (T == i32 or T == i64 or T == u8 or T == u16 or T == u32 or T == u64 or T == usize) return valueToInt(T, value);
            if (T == bool) return value.asBool();
            if (T == []const u8) return value.asString();

            // Enums
            if (info == .@"enum") {
                const name = value.asString() orelse return null;
                return std.meta.stringToEnum(T, name);
            }

            // Tagged unions
            if (info == .@"union") {
                if (info.@"union".tag_type != null) {
                    return deserializeTaggedUnion(T, value, allocator);
                }
                return null;
            }

            // EnumSet-like types
            if (info == .@"struct" and @hasDecl(T, "initEmpty") and @hasDecl(T, "insert")) {
                return deserializeEnumSet(T, value);
            }

            // Structs
            if (info == .@"struct") {
                return deserializeStruct(T, value, allocator);
            }

            return null;
        }

        fn valueToFloat(comptime T: type, value: Value) ?T {
            return switch (value) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        }

        fn valueToInt(comptime T: type, value: Value) ?T {
            return switch (value) {
                .integer => |i| std.math.cast(T, i),
                .float => |f| blk: {
                    const rounded: i64 = @intFromFloat(f);
                    break :blk std.math.cast(T, rounded);
                },
                else => null,
            };
        }

        fn deserializeStruct(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
            const obj = value.asObject() orelse return null;
            const fields = @typeInfo(T).@"struct".fields;
            var result: T = undefined;

            inline for (fields) |field| {
                if (obj.get(field.name)) |field_val| {
                    if (deserialize(field.type, field_val, allocator)) |v| {
                        @field(result, field.name) = v;
                    } else if (field.default_value_ptr) |ptr| {
                        const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
                        @field(result, field.name) = default.*;
                    } else {
                        return null;
                    }
                } else if (field.default_value_ptr) |ptr| {
                    const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
                    @field(result, field.name) = default.*;
                } else {
                    return null;
                }
            }

            return result;
        }

        fn deserializeTaggedUnion(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
            const obj = value.asObject() orelse return null;
            if (obj.entries.len != 1) return null;
            const entry = obj.entries[0];

            inline for (@typeInfo(T).@"union".fields) |field| {
                if (std.mem.eql(u8, entry.key, field.name)) {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    }
                    if (deserialize(field.type, entry.value, allocator)) |payload| {
                        return @unionInit(T, field.name, payload);
                    }
                    return null;
                }
            }
            return null;
        }

        fn deserializeEnumSet(comptime T: type, value: Value) ?T {
            const obj = value.asObject() orelse return null;
            var set = T.initEmpty();
            for (obj.entries) |entry| {
                const is_true = entry.value.asBool() orelse false;
                if (is_true) {
                    if (std.meta.stringToEnum(T.Key, entry.key)) |key| {
                        set.insert(key);
                    }
                }
            }
            return set;
        }

        /// Apply a single named component to an entity.
        fn applyComponent(game: *GameType, entity: Entity, name: []const u8, value: Value, parent_offset: Position) void {
            // Position — uses setPosition, offset by parent position
            if (std.mem.eql(u8, name, "Position")) {
                if (value.asObject()) |obj| {
                    var pos = Position{};
                    if (obj.getInteger("x")) |x| {
                        pos.x = @floatFromInt(x);
                    } else if (obj.getFloat("x")) |x| {
                        pos.x = @floatCast(x);
                    }
                    if (obj.getInteger("y")) |y| {
                        pos.y = @floatFromInt(y);
                    } else if (obj.getFloat("y")) |y| {
                        pos.y = @floatCast(y);
                    }
                    game.setPosition(entity, .{ .x = parent_offset.x + pos.x, .y = parent_offset.y + pos.y });
                }
                return;
            }

            // Sprite — uses addSprite for renderer registration
            if (std.mem.eql(u8, name, "Sprite")) {
                if (deserialize(Sprite, value, game.allocator)) |sprite| {
                    game.addSprite(entity, sprite);
                }
                return;
            }

            // Shape — uses addShape for renderer registration
            if (std.mem.eql(u8, name, "Shape")) {
                if (deserialize(Shape, value, game.allocator)) |shape| {
                    game.addShape(entity, shape);
                }
                return;
            }

            // All other components — comptime dispatch via Components registry.
            const filtered = stripEntityArrayFields(value, game.allocator);
            defer {
                // Free the filtered entries slice if it was newly allocated
                if (filtered.asObject()) |fo| {
                    if (value.asObject()) |orig| {
                        if (fo.entries.ptr != orig.entries.ptr) {
                            game.allocator.free(fo.entries);
                        }
                    }
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (deserialize(T, filtered, game.allocator)) |component| {
                        game.addComponent(entity, component);
                    }
                    return;
                }
            }
        }
    };
}

/// JSONC scene bridge with gizmo reconciliation.
pub fn JsoncSceneBridgeWithGizmos(
    comptime GameType: type,
    comptime Components: type,
    comptime GizmoReg: type,
) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;
    const Gizmo = core.GizmoComponent(Entity);
    const Writer = scene_mod.EntityWriter(GameType, Components);
    const GizmoAttached = struct { _: u8 = 1 };
    const BaseBridge = JsoncSceneBridge(GameType, Components);

    return struct {
        /// Load a JSONC scene file and set up gizmo reconciliation.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            try BaseBridge.loadScene(game, scene_path, prefab_dir);
            game.gizmo_reconcile_fn = &reconcileGizmos;
        }

        /// Load a scene from an in-memory JSONC source string and set up gizmo reconciliation.
        pub fn loadSceneFromSource(game: *GameType, source: []const u8, prefab_dir: []const u8) !void {
            try BaseBridge.loadSceneFromSource(game, source, prefab_dir);
            game.gizmo_reconcile_fn = &reconcileGizmos;
        }

        /// Per-frame gizmo reconciliation.
        fn reconcileGizmos(game: *GameType) void {
            inline for (GizmoReg.fields) |field| {
                reconcileForGizmo(game, field.name);
            }
        }

        fn reconcileForGizmo(game: *GameType, comptime gizmo_name: []const u8) void {
            const gizmo_data = comptime GizmoReg.get(gizmo_name);
            const GizmoData = @TypeOf(gizmo_data);
            const has_match = comptime @hasField(GizmoData, "match");
            const has_exclude = comptime @hasField(GizmoData, "exclude");

            const has_primary = comptime blk: {
                if (has_match) {
                    const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                    if (match_fields.len == 0) @compileError("Gizmo '" ++ gizmo_name ++ "' has empty .match");
                    const first_name = @field(gizmo_data.match, match_fields[0].name);
                    if (!Components.has(first_name)) @compileError("Gizmo '" ++ gizmo_name ++ "' matches '" ++ first_name ++ "' not in ComponentRegistry");
                    break :blk true;
                } else {
                    const component_name = gizmo_mod.snakeToPascal(gizmo_name);
                    break :blk Components.has(component_name);
                }
            };

            if (!has_primary) return;

            const PrimaryType = comptime blk: {
                if (has_match) {
                    const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                    const first_name = @field(gizmo_data.match, match_fields[0].name);
                    break :blk Components.getType(first_name);
                } else {
                    break :blk Components.getType(gizmo_mod.snakeToPascal(gizmo_name));
                }
            };

            var buf: [64]Entity = undefined;
            var count: usize = 0;

            {
                var v = game.ecs_backend.view(.{PrimaryType}, .{GizmoAttached});
                while (v.next()) |entity| {
                    if (count < buf.len and matchesGizmoRules(entity, game, gizmo_data, has_match, has_exclude)) {
                        buf[count] = entity;
                        count += 1;
                    }
                }
                v.deinit();
            }

            for (buf[0..count]) |entity| {
                const pos = game.getPosition(entity);
                createGizmosForName(gizmo_name, entity, game, .{ .x = pos.x, .y = pos.y });
                game.ecs_backend.addComponent(entity, GizmoAttached{});
            }
        }

        fn matchesGizmoRules(
            entity: Entity,
            game: *GameType,
            comptime gizmo_data: anytype,
            comptime has_match: bool,
            comptime has_exclude: bool,
        ) bool {
            if (has_match) {
                const match_fields = @typeInfo(@TypeOf(gizmo_data.match)).@"struct".fields;
                inline for (match_fields[1..]) |f| {
                    const name = @field(gizmo_data.match, f.name);
                    const T = Components.getType(name);
                    if (game.ecs_backend.getComponent(entity, T) == null) return false;
                }
            }
            if (has_exclude) {
                const exclude_fields = @typeInfo(@TypeOf(gizmo_data.exclude)).@"struct".fields;
                inline for (exclude_fields) |f| {
                    const name = @field(gizmo_data.exclude, f.name);
                    const T = Components.getType(name);
                    if (game.ecs_backend.getComponent(entity, T) != null) return false;
                }
            }
            return true;
        }

        fn createGizmosForName(comptime gizmo_name: []const u8, entity: Entity, game: *GameType, parent_pos: struct { x: f32 = 0, y: f32 = 0 }) void {
            if (comptime GizmoReg.has(gizmo_name)) {
                if (comptime GizmoReg.getEntityGizmos(gizmo_name)) |gizmos| {
                    createGizmoEntities(gizmos, entity, game, parent_pos);
                }
            }
        }

        fn createGizmoEntities(comptime gizmos_data: anytype, parent_entity: Entity, game: *GameType, parent_pos: anytype) void {
            inline for (@typeInfo(@TypeOf(gizmos_data)).@"struct".fields) |field| {
                const gizmo_data = @field(gizmos_data, field.name);

                const gizmo_entity = game.createEntity();

                const offset_x: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "x")) gizmo_data.x else 0;
                const offset_y: f32 = comptime if (@hasField(@TypeOf(gizmo_data), "y")) gizmo_data.y else 0;

                game.ecs_backend.addComponent(gizmo_entity, Gizmo{
                    .parent_entity = parent_entity,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                });

                game.setPosition(gizmo_entity, .{
                    .x = parent_pos.x + offset_x,
                    .y = parent_pos.y + offset_y,
                });

                if (comptime std.mem.eql(u8, field.name, "Shape")) {
                    var shape = Writer.coerce(Shape, gizmo_data);
                    if (comptime @hasField(@TypeOf(shape.layer), "world"))
                        shape.layer = .world;
                    game.addShape(gizmo_entity, shape);
                } else if (comptime std.mem.eql(u8, field.name, "Sprite")) {
                    var sprite = Writer.coerce(Sprite, gizmo_data);
                    if (comptime @hasField(@TypeOf(sprite.layer), "world"))
                        sprite.layer = .world;
                    game.addSprite(gizmo_entity, sprite);
                }
            }
        }
    };
}
