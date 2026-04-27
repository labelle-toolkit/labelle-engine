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
// Slice 1 of #495: the JSONC → Zig-struct deserializer (≈200
// lines, no GameType/Components dependency) lives in its own file.
// Public surface is just `deserializer.deserialize`; the recursive
// helpers stay file-local on the other side.
const deserializer = @import("jsonc/deserializer.zig");
// Slice 2 of #495: two-pass `@ref` resolution. Generic over both
// `GameType` and `Components` so each bridge instantiation gets its
// own typed `RefContext` / `DeferredRefField`.
const ref_resolver_mod = @import("jsonc/ref_resolver.zig");
// Slice 3 of #495: component `onReady` / `postLoad` hook firing +
// the `[]const u64` field-patcher used by the nested-entity spawn
// path. Pure comptime dispatch over `Components`.
const on_ready_mod = @import("jsonc/on_ready.zig");

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

        /// Reuse the game's attached PrefabCache when one exists, refreshing
        /// its `prefab_dir` so filesystem fallback lookups track the current
        /// scene's directory. Otherwise allocate a fresh persistent cache.
        ///
        /// Shared by `loadScene`, `loadSceneFromSource` and `addEmbeddedPrefab`
        /// so the three entry points can never drift apart on this critical
        /// path — see the !!! CRITICAL !!! block in `loadSceneFromSource` for
        /// the mobile-build failure mode this protects against.
        fn getOrCreatePrefabCache(game: *GameType, prefab_dir: []const u8) !*PrefabCache {
            if (game.prefab_cache_ptr) |ptr| {
                const cache = @as(*PrefabCache, @ptrCast(@alignCast(ptr)));
                cache.prefab_dir = prefab_dir;
                return cache;
            }
            return try initPersistentCache(game, prefab_dir);
        }

        /// Load a JSONC scene file and instantiate all entities in the ECS.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            // Reuse any existing cache so prefabs registered via
            // `addEmbeddedPrefab` before `loadScene` runs survive — same
            // failure mode as `loadSceneFromSource`, just less commonly
            // hit because filesystem-based `loadScene` is a desktop path.
            const prefab_cache = try getOrCreatePrefabCache(game, prefab_dir);

            try loadSceneFile(game, scene_path, prefab_cache, 0);

            // Enable runtime prefab spawning
            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Load a scene from an in-memory JSONC source string (for embedded/release builds).
        /// The source must outlive the loaded scene — typically a comptime `@embedFile` slice.
        pub fn loadSceneFromSource(game: *GameType, source: []const u8, prefab_dir: []const u8) !void {
            // ================================================================
            // !!! CRITICAL — DO NOT REPLACE WITH `initPersistentCache` !!!
            // ================================================================
            //
            // This MUST reuse an existing PrefabCache when one is already
            // attached to the game. The cache is populated up-front by
            // `addEmbeddedPrefab` calls that the assembler emits in init()
            // for every `prefabs/*.jsonc` in the project — the only mechanism
            // by which prefabs are made available to mobile builds (Android,
            // iOS), where the app has no filesystem access.
            //
            // If we instead create a fresh cache here (the obvious-looking
            // `try initPersistentCache(...)` one-liner), every embedded
            // prefab is silently discarded. Subsequent lookups in
            // `PrefabCache.get` then fall through to
            // `std.fs.cwd().openFile("prefabs/<name>.jsonc")`. On desktop
            // that "happens to work" because the project directory is the
            // cwd — and that accidental success is what masked this bug for
            // ages. On Android the openFile returns `error.FileNotFound`,
            // `get` returns null, and **every nested prefab entity
            // (workstations, storages, movement_nodes, …) silently fails
            // to spawn**. The visible symptom is a black screen with the
            // simulation alive but no rooms — exactly what bit
            // flying-platform-labelle when first deployed to the emulator.
            //
            // Past tense, present danger: any "tidy-up" refactor that
            // replaces the conditional below with an unconditional call to
            // `initPersistentCache` will reintroduce the regression. The
            // assembler's `addEmbeddedPrefab` ordering is fixed — it runs
            // BEFORE `setScene`/`loadSceneFromSource` — so the cache is
            // ALWAYS already populated by the time we get here on a properly
            // generated build. Reuse it. Don't replace it.
            //
            // See:
            //   - flying-platform-labelle Android black-screen debug
            //     (entityCount went from 19 → 125, pathfinder graph
            //     0 → 39 nodes after this fix)
            //   - PR for this fix in labelle-engine
            //   - Mirrors the same defensive pattern already used by
            //     `addEmbeddedPrefab` itself (line ~92 in this file)
            // ================================================================
            const prefab_cache = try getOrCreatePrefabCache(game, prefab_dir);

            try loadSceneSource(game, source, prefab_cache);

            // Enable runtime prefab spawning
            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Pre-load a prefab from an in-memory JSONC source into the persistent cache.
        /// Call this before loadSceneFromSource to make prefabs available without file I/O.
        /// The source must outlive the game — typically a comptime `@embedFile` slice.
        pub fn addEmbeddedPrefab(game: *GameType, name: []const u8, source: []const u8, prefab_dir: []const u8) !void {
            const prefab_cache = try getOrCreatePrefabCache(game, prefab_dir);

            const persistent = prefab_cache.persistent;
            var parser = JsoncParser.init(persistent, source);
            const val = try parser.parse();
            try prefab_cache.prefabs.put(try persistent.dupe(u8, name), val);
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
            game.trackSceneEntity(entity);
            game.setPosition(entity, pos);

            // Apply all prefab components — use pos as parent_offset so
            // prefab positions are relative to the spawn point.
            for (prefab_components.entries) |entry| {
                applyComponent(game, entity, entry.key, entry.value, pos);
            }

            // Handle nested entities (e.g. workstation storages)
            const entity_pos = game.getPosition(entity);
            for (prefab_components.entries) |entry| {
                spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, 0, null);
            }

            // Fire onReady hooks
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();
            fireOnReadyAll(game, entity, null, prefab_components, &applied);

            // Process children — save world pos, set parent, restore (#417)
            if (prefab_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    const child = loadEntityInternal(game, child_val, prefab_cache, 1, entity_pos, null) catch continue;
                    const world_pos = game.getPosition(child);
                    game.setParent(child, entity, .{});
                    game.setWorldPosition(child, world_pos);
                }
            }

            return entity;
        }

        // ================================================================
        // Entity cross-references (@ref syntax)
        // ================================================================

        const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
        const RefContext = RefResolver.RefContext;
        const DeferredRefField = RefResolver.DeferredRefField;
        const valueHasRefs = RefResolver.valueHasRefs;
        const replaceRefsWithZero = RefResolver.replaceRefsWithZero;
        const collectDeferredRefFields = RefResolver.collectDeferredRefFields;
        const patchRefField = RefResolver.patchRefField;

        /// Process entities from a parsed scene, with two-pass ref resolution.
        fn processEntities(game: *GameType, entities_arr: Value.Array, prefab_cache: *PrefabCache, ref_ctx: *RefContext) LoadEntityError!void {
            // Pass 1: create entities, apply components (with @ref→0), collect refs
            for (entities_arr.items) |entity_val| {
                _ = try loadEntityInternal(game, entity_val, prefab_cache, 0, .{ .x = 0, .y = 0 }, ref_ctx);
            }

            // Pass 2: patch @ref fields with resolved entity IDs
            for (ref_ctx.deferred.items) |deferred| {
                patchRefField(game, deferred, ref_ctx);
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
                var ref_ctx = RefContext.init(game.allocator, null);
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
                var ref_ctx = RefContext.init(game.allocator, null);
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

        const LoadEntityError = error{ IncludeDepthExceeded, OutOfMemory, InvalidFormat };

        /// Unified entity loader — handles top-level and child entities, with
        /// optional ref context for @ref cross-reference support.
        /// When ref_ctx is non-null, registers "ref" names and applies components
        /// with @ref strings replaced by 0 (patched in pass 2).
        /// When ref_ctx is null, follows the original single-pass path.
        fn loadEntityInternal(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position, ref_ctx: ?*RefContext) LoadEntityError!Entity {
            if (depth > MAX_DEPTH) return error.IncludeDepthExceeded;
            const entity_obj = entity_val.asObject() orelse return error.InvalidFormat;

            // Resolve prefab
            var prefab_components: ?Value.Object = null;
            var prefab_children: ?Value.Array = null;
            var prefab_obj_opt: ?Value.Object = null;
            if (entity_obj.getString("prefab")) |prefab_name| {
                if (prefab_cache.get(prefab_name)) |prefab_val| {
                    if (prefab_val.asObject()) |pobj| {
                        prefab_obj_opt = pobj;
                        prefab_components = pobj.getObject("components");
                        prefab_children = pobj.getArray("children");
                    }
                }
            }

            const scene_components = entity_obj.getObject("components");

            // Create entity — destroy on error to prevent orphans
            const entity = game.createEntity();
            game.trackSceneEntity(entity);
            errdefer game.destroyEntity(entity);

            // Register ref name if ref context is active.
            // Scene-level ref overrides prefab-level ref.
            // Note: @ref is scoped to a single scene file — refs from included
            // files are not visible (each file gets its own RefContext).
            if (ref_ctx) |rctx| {
                const entity_id: u64 = @intCast(entity);
                const ref_name = entity_obj.getString("ref") orelse
                    if (prefab_obj_opt) |pobj| pobj.getString("ref") else null;
                if (ref_name) |rn| {
                    if (try rctx.ref_map.fetchPut(rn, entity_id)) |existing| {
                        game.log.warn("[SceneRef] Duplicate ref '{s}' (entities {d} and {d})", .{ rn, existing.value, entity_id });
                    }
                }
            }

            // Build merged component map: prefab defaults, then scene overrides
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            // Apply scene components (these override prefab defaults)
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    try applyComponentWithRefs(game, entity, entry.key, entry.value, parent_offset, ref_ctx);
                    try applied.put(entry.key, {});
                }
            }

            // Apply prefab components (skip if already overridden by scene)
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        try applyComponentWithRefs(game, entity, entry.key, entry.value, parent_offset, ref_ctx);
                    }
                }
            }

            // Get this entity's world position for offsetting nested children
            const entity_pos = game.getPosition(entity);

            // Spawn nested entity arrays and collect IDs to patch back into components
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth, ref_ctx);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth, ref_ctx);
                    }
                }
            }

            // Fire onReady for all applied components (after entity is fully assembled)
            fireOnReadyAll(game, entity, scene_components, prefab_components, &applied);

            // Process children recursively (prefab children + entity-level children).
            // loadEntityInternal already applied parent_offset to the child's Position
            // (world coords). setParent would double-offset via computeWorldTransform,
            // so we save the world pos, set parent, then restore it (#417).
            //
            // When a child is itself a prefab instance, it gets its own local
            // RefContext so prefab-internal refs (e.g. `ref: "storage"` inside
            // `food_storage_with_packet`) don't collide across sibling
            // instances of the same prefab. This mirrors the pattern already
            // used by `spawnAndLinkNestedEntities` for entities nested inside
            // component array fields. See engine #425 / flying-platform #53.
            //
            // Plain children (no `prefab` key) keep using the parent's ref_ctx
            // so scene-level cross-references between top-level entities still
            // work as before.
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    try loadChildEntity(game, entity, child_val, prefab_cache, depth, entity_pos, ref_ctx);
                }
            }

            // Save/load: tag prefab-sourced entities with `PrefabInstance`
            // (root) + `PrefabChild` (each descendant) so the save mixin
            // records their prefab origin and the two-phase load can
            // respawn the prefab + remap saved child IDs to the newly-
            // spawned descendants via `(root, local_path)`. Uses the
            // shared `game.tagAsPrefabInstance` so the `local_path`
            // format stays identical to the runtime `spawnFromPrefab`
            // path — save mixin's `findChildByLocalPath` can match
            // either.
            //
            // Tag BEFORE scene-declared children are attached. If a scene
            // over-declares children on top of a prefab (e.g. the scene
            // adds decorations around a prefab-sourced room), those
            // scene-only children must NOT get `PrefabChild` markers —
            // they don't belong to the prefab definition, and on load
            // Phase 1b would otherwise walk `children[N]` and either
            // miss (prefab grew fewer children than saved) or mis-map
            // onto a newly-added prefab child at the same index (prefab
            // evolved). Propagate the error via `try` instead of logging
            // and continuing: an untagged prefab root is invisible to
            // Phase 1a, so a silent failure breaks F5 → F9 round-trip.
            // `LoadEntityError` already carries `OutOfMemory`.
            if (entity_obj.getString("prefab")) |prefab_name| {
                try game.tagAsPrefabInstance(entity, prefab_name);
            }

            if (entity_obj.getArray("children")) |children| {
                for (children.items) |child_val| {
                    try loadChildEntity(game, entity, child_val, prefab_cache, depth, entity_pos, ref_ctx);
                }
            }

            return entity;
        }

        /// Load a single child entity and attach it to its parent. Handles
        /// the per-instance ref-scoping wrapper when the child is itself a
        /// prefab instance — see the comment in the caller for the rationale.
        fn loadChildEntity(
            game: *GameType,
            parent_entity: Entity,
            child_val: Value,
            prefab_cache: *PrefabCache,
            depth: usize,
            parent_pos: Position,
            ref_ctx: ?*RefContext,
        ) LoadEntityError!void {
            const child_obj = child_val.asObject();
            const child_is_prefab = if (child_obj) |cobj| cobj.getString("prefab") != null else false;

            const child = if (child_is_prefab and ref_ctx != null) blk: {
                // Per-instance ref scope for prefab children. Chained to
                // the parent scope so a prefab-body entity can still
                // resolve refs declared in an enclosing scope (e.g.
                // `food_packet` inside `food_storage_with_packet` looking
                // up its parent's `@storage`). Registrations stay local
                // so repeated sibling instances of the same prefab don't
                // collide on their internal ref names.
                var local_ctx = RefContext.init(game.allocator, ref_ctx);
                defer local_ctx.deinit();

                const c = try loadEntityInternal(game, child_val, prefab_cache, depth + 1, parent_pos, &local_ctx);

                // If the child was given a scene-level ref override, bubble
                // it up to the parent scope so siblings and the parent
                // entity can reference this child. Prefab-internal refs
                // stay local.
                if (ref_ctx) |rctx| {
                    if (child_obj) |cobj| {
                        if (cobj.getString("ref")) |scene_ref| {
                            if (local_ctx.ref_map.get(scene_ref)) |eid| {
                                if (try rctx.ref_map.fetchPut(scene_ref, eid)) |existing| {
                                    game.log.warn("[SceneRef] Duplicate ref '{s}' (entities {d} and {d})", .{ scene_ref, existing.value, eid });
                                }
                            }
                        }
                    }
                }

                // Patch deferred refs collected inside the local context.
                // Lookups walk up the parent chain, so refs that point at
                // an ancestor scope (e.g. `@storage` inside a nested
                // prefab body) resolve correctly.
                for (local_ctx.deferred.items) |deferred| {
                    patchRefField(game, deferred, &local_ctx);
                }

                break :blk c;
            } else
                // Plain child: uses the parent's ref_ctx so scene-level
                // cross-references still work.
                try loadEntityInternal(game, child_val, prefab_cache, depth + 1, parent_pos, ref_ctx);

            // Save world pos before setParent to avoid double-offset (#417).
            const world_pos = game.getPosition(child);
            game.setParent(child, parent_entity, .{});
            game.setWorldPosition(child, world_pos);
        }

        /// Apply a component, handling @ref substitution when ref_ctx is active.
        /// Components with @ref strings are applied with 0 placeholders through
        /// the full applyComponent pipeline, and their ref fields are collected
        /// for patching in pass 2.
        fn applyComponentWithRefs(game: *GameType, entity: Entity, comp_name: []const u8, value: Value, parent_offset: Position, ref_ctx: ?*RefContext) !void {
            if (ref_ctx) |rctx| {
                if (valueHasRefs(comp_name, value)) {
                    // Replace @ref strings with 0 so the full pipeline works.
                    // Allocate buffer sized to the object's entry count.
                    const obj = value.asObject() orelse {
                        applyComponent(game, entity, comp_name, value, parent_offset);
                        return;
                    };
                    const entries = try game.allocator.alloc(Value.Object.Entry, obj.entries.len);
                    defer game.allocator.free(entries);
                    const zeroed = replaceRefsWithZero(comp_name, value, entries) orelse value;
                    applyComponent(game, entity, comp_name, zeroed, parent_offset);
                    // Record which fields need patching in pass 2
                    try collectDeferredRefFields(rctx, entity, comp_name, value);
                    return;
                }
            }
            applyComponent(game, entity, comp_name, value, parent_offset);
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
            ref_ctx: ?*RefContext,
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
                        game.trackSceneEntity(child);

                        if (item.asObject()) |child_obj| {
                            var child_prefab_comps: ?Value.Object = null;
                            var child_prefab_children: ?Value.Array = null;
                            if (child_obj.getString("prefab")) |pname| {
                                if (prefab_cache.get(pname)) |pval| {
                                    if (pval.asObject()) |pobj| {
                                        child_prefab_comps = pobj.getObject("components");
                                        child_prefab_children = pobj.getArray("children");
                                    }
                                }
                            }

                            // Register scene-level ref in the parent's ref context.
                            // Only explicit "ref" on the nested entity (not from the prefab)
                            // goes into the parent scope — prefab-internal refs are scoped
                            // per-instance below to avoid collisions between repeated prefabs.
                            if (ref_ctx) |rctx| {
                                if (child_obj.getString("ref")) |rn| {
                                    const entity_id: u64 = @intCast(child);
                                    if (rctx.ref_map.fetchPut(rn, entity_id) catch null) |existing| {
                                        game.log.warn("[SceneRef] Duplicate ref '{s}' (entities {d} and {d})", .{ rn, existing.value, entity_id });
                                    }
                                }
                            }

                            // Use a local RefContext for this nested entity's children so that
                            // prefab-internal refs (e.g. @storage/@item in eis_with_water) are
                            // scoped per-instance and don't collide across repeated prefabs.
                            // Chained to the caller's ref_ctx so prefab bodies can still
                            // resolve refs from enclosing scopes via parent-chain lookup.
                            var local_ref_ctx = RefContext.init(game.allocator, ref_ctx);
                            defer local_ref_ctx.deinit();
                            const nested_ref_ctx: *RefContext = &local_ref_ctx;

                            // Register the nested entity in the local context so its
                            // children can reference it via @ref. Always register the
                            // prefab-defined ref (for internal @refs like @storage),
                            // plus the scene-level ref if different (as an alias).
                            {
                                const entity_id: u64 = @intCast(child);
                                const scene_ref = child_obj.getString("ref");
                                var prefab_ref: ?[]const u8 = null;
                                if (child_obj.getString("prefab")) |pname| {
                                    if (prefab_cache.get(pname)) |pval| {
                                        if (pval.asObject()) |pobj| {
                                            prefab_ref = pobj.getString("ref");
                                        }
                                    }
                                }
                                if (prefab_ref) |prn| {
                                    local_ref_ctx.ref_map.put(prn, entity_id) catch {};
                                }
                                if (scene_ref) |srn| {
                                    const is_same = if (prefab_ref) |prn| std.mem.eql(u8, srn, prn) else false;
                                    if (!is_same) {
                                        local_ref_ctx.ref_map.put(srn, entity_id) catch {};
                                    }
                                }
                            }

                            const child_scene_comps = child_obj.getObject("components");

                            // Scene overrides first
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    applyComponentWithRefs(game, child, e.key, e.value, parent_world_pos, nested_ref_ctx) catch |err| {
                                        game.log.err("[NestedEntity] Failed to apply {s}: {s}", .{ e.key, @errorName(err) });
                                    };
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
                                        applyComponentWithRefs(game, child, e.key, e.value, parent_world_pos, nested_ref_ctx) catch |err| {
                                            game.log.err("[NestedEntity] Failed to apply {s}: {s}", .{ e.key, @errorName(err) });
                                        };
                                    }
                                }
                            }

                            // Recursively spawn nested entities inside this child's components
                            const child_pos = game.getPosition(child);
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    spawnAndLinkNestedEntities(game, child, e.key, e.value, child_pos, prefab_cache, depth + 1, nested_ref_ctx);
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
                                        spawnAndLinkNestedEntities(game, child, e.key, e.value, child_pos, prefab_cache, depth + 1, nested_ref_ctx);
                                    }
                                }
                            }

                            // Process children (prefab children + inline children) (#415)
                            // Process children — save world pos before setParent to
                            // avoid double-offset (#417)
                            if (child_prefab_children) |children| {
                                for (children.items) |child_val| {
                                    const grandchild = loadEntityInternal(game, child_val, prefab_cache, depth + 1, child_pos, nested_ref_ctx) catch |err| {
                                        game.log.err("[NestedEntity] Failed to load child: {s}", .{@errorName(err)});
                                        continue;
                                    };
                                    const gc_world = game.getPosition(grandchild);
                                    game.setParent(grandchild, child, .{});
                                    game.setWorldPosition(grandchild, gc_world);
                                }
                            }
                            if (child_obj.getArray("children")) |children| {
                                for (children.items) |child_val| {
                                    const grandchild = loadEntityInternal(game, child_val, prefab_cache, depth + 1, child_pos, nested_ref_ctx) catch |err| {
                                        game.log.err("[NestedEntity] Failed to load child: {s}", .{@errorName(err)});
                                        continue;
                                    };
                                    const gc_world = game.getPosition(grandchild);
                                    game.setParent(grandchild, child, .{});
                                    game.setWorldPosition(grandchild, gc_world);
                                }
                            }

                            // Patch deferred refs from the local context.
                            // Lookups walk up the parent chain to resolve
                            // refs that point at an enclosing scope.
                            for (local_ref_ctx.deferred.items) |deferred| {
                                patchRefField(game, deferred, &local_ref_ctx);
                            }

                            // Fire onReady + postLoad for this nested child
                            // now that its components, nested entities, and
                            // refs are all in place. Parity with the
                            // top-level `fireOnReadyAll` in `loadEntityInternal`
                            // — without this, components declared on nested
                            // entities (e.g. `Workstation.postLoad` inside a
                            // Room's `workstations` array) never run.
                            //
                            // Pre-populate `applied` with scene component
                            // names so `fireOnReadyAll`'s prefab-loop
                            // `contains` check skips prefab entries that
                            // the scene already overrode. Otherwise any
                            // component present in BOTH maps would fire
                            // its hooks twice (once from the scene loop,
                            // once from the prefab loop).
                            var nested_applied = std.StringHashMap(void).init(game.allocator);
                            defer nested_applied.deinit();
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    nested_applied.put(e.key, {}) catch {};
                                }
                            }
                            fireOnReadyAll(game, child, child_scene_comps, child_prefab_comps, &nested_applied);
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

        const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);
        const fireOnReadyAll = OnReadyHelpers.fireOnReadyAll;
        const fireOnReadyByName = OnReadyHelpers.fireOnReadyByName;
        const patchEntityIdField = OnReadyHelpers.patchEntityIdField;

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

            // `deserialize`-side allocations (slices for `frames` /
            // `entries` / etc.) land in `active_world.nested_entity_arena`
            // so they share the lifetime of the spawned entity —
            // freed atomically on scene change via `resetEcsBackend`.
            // `game.allocator` was tempting as a default but leaves
            // nothing to free per-scene, which bit us on #488
            // (gemini flagged unbounded per-spawn slice growth). The
            // transient `stripEntityArrayFields` scratch below still
            // uses `game.allocator` because its lifetime is this
            // function call only and the `defer` above frees it.
            const comp_alloc = game.active_world.nested_entity_arena.allocator();

            // Sprite — uses addSprite for renderer registration
            if (std.mem.eql(u8, name, "Sprite")) {
                if (deserializer.deserialize(Sprite, value, comp_alloc)) |sprite| {
                    game.addSprite(entity, sprite);
                }
                return;
            }

            // Shape — uses addShape for renderer registration
            if (std.mem.eql(u8, name, "Shape")) {
                if (deserializer.deserialize(Shape, value, comp_alloc)) |shape| {
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
                    if (deserializer.deserialize(T, filtered, comp_alloc)) |component| {
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

        /// Pre-load a prefab from embedded JSONC source. Delegates to BaseBridge.
        pub fn addEmbeddedPrefab(game: *GameType, name: []const u8, source: []const u8, prefab_dir: []const u8) !void {
            return BaseBridge.addEmbeddedPrefab(game, name, source, prefab_dir);
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
                game.trackSceneEntity(gizmo_entity);

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
