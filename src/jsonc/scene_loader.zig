//! Scene/prefab loader — the recursive entity-tree walker that
//! turns a parsed JSONC `Value` into ECS entities. Slice 5 of #495.
//!
//! Composes the smaller modules already extracted:
//!   - `prefab_cache.zig`     — looks up `prefab` references
//!   - `ref_resolver.zig`     — registers and patches `@ref` fields
//!   - `component_apply.zig`  — turns a component `Value` into a
//!                              real ECS component
//!   - `on_ready.zig`         — fires `onReady` / `postLoad` hooks
//!
//! The public entry points (`loadScene`, `loadSceneFromSource`,
//! `addEmbeddedPrefab`) live here too; the bridge file
//! (`jsonc_scene_bridge.zig`) is now a thin shell that just
//! re-exports them under the `JsoncSceneBridge(GameType, Components)`
//! signature the rest of the codebase already calls into.

const std = @import("std");
const io_helper = @import("../io_helper.zig");
const builtin = @import("builtin");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;
const core = @import("labelle-core");
const Position = core.Position;

// Game-lifetime allocator for persistent ID arrays. On
// `wasm32-emscripten` we MUST use libc malloc, not Zig's
// `page_allocator` (which is `WasmAllocator` there) — the latter
// calls `@wasmMemoryGrow` directly, bypassing emscripten's
// `updateMemoryViews()` and detaching the JS-side `HEAPU32`. The next
// `_fd_write` (i.e. the first `std.debug.print` after a grow) aborts.
// Desktop targets keep `page_allocator` so the existing convention
// "deliberately not freed → page allocator so GPA doesn't flag" is
// preserved. See `labelle-cli/docs/wasm-segfault-investigation.md` (#196).
const persistent_id_allocator: std.mem.Allocator = if (builtin.target.os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;

const prefab_cache_mod = @import("prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const uf = @import("unified_format.zig");
const ref_resolver_mod = @import("ref_resolver.zig");
const component_apply_mod = @import("component_apply.zig");
const on_ready_mod = @import("on_ready.zig");
const tree_walker = @import("tree_walker.zig");

/// Adapt a `PrefabCache` into a `tree_walker.Resolver`. The walker
/// expands `prefab` references through this so its cycle detector
/// sees the same reference graph the instantiation pass does.
fn prefabResolver(cache: *PrefabCache) tree_walker.Resolver {
    const Wrap = struct {
        fn get(ctx: *anyopaque, name: []const u8) ?Value {
            const c: *PrefabCache = @ptrCast(@alignCast(ctx));
            return c.get(name);
        }
    };
    return .{ .ctx = cache, .getFn = &Wrap.get };
}

/// A walker visitor that does nothing — used when the only thing a
/// walk needs to surface is cycle detection (the walker raises
/// `error.PrefabCycle` on its own; the visitor never has to act).
const CycleCheckVisitor = struct {
    pub const VisitError = error{};
    pub fn visit(_: CycleCheckVisitor, _: tree_walker.Node(VisitError)) VisitError!void {}
};

pub fn SceneLoader(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;
    const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
    const RefContext = RefResolver.RefContext;
    const ApplyHelpers = component_apply_mod.ComponentApply(GameType, Components);
    const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);

    return struct {
        pub const LoadEntityError = error{ IncludeDepthExceeded, OutOfMemory, InvalidFormat, PrefabCycle };
        pub const MAX_DEPTH: usize = 16;

        // ── Cycle detection (RFC #569) ─────────────────────────

        /// Run the shared entity-tree walker over `entity_value`
        /// purely for its cycle detector. A referenced-prefab cycle
        /// (`A -> B -> A`) is a load-time error: the full chain is
        /// logged and `error.PrefabCycle` propagates so the loader
        /// aborts before instantiating a tree that would recurse
        /// forever. Both inference (static) and instantiation
        /// (runtime) gate on this shared check.
        fn checkEntityTreeCycles(
            game: *GameType,
            entity_value: Value,
            prefab_cache: *PrefabCache,
            ctx: *tree_walker.WalkContext,
        ) LoadEntityError!void {
            // Track the loader's recursion limit so the walk fails
            // with the same depth ceiling `loadEntityInternal` does
            // — a tree the loader would reject as too deep is
            // surfaced here as `IncludeDepthExceeded`, not silently
            // walked.
            ctx.max_depth = MAX_DEPTH;
            tree_walker.walk(ctx, prefabResolver(prefab_cache), entity_value, CycleCheckVisitor{}) catch |err| switch (err) {
                error.PrefabCycle => {
                    // `formatCycleChain` either returns an
                    // allocator-owned slice (success) or raises
                    // `OutOfMemory`. Use an optional to signal which
                    // one, rather than a literal-string fallback —
                    // a string-equality probe to decide whether to
                    // free is brittle (and just happens to work
                    // because no real chain is "<unknown>").
                    const chain_opt: ?[]const u8 = ctx.formatCycleChain(game.allocator) catch null;
                    defer if (chain_opt) |c| game.allocator.free(c);
                    const chain = chain_opt orelse "<unknown>";
                    game.log.err("[scene] prefab reference cycle: {s} (RFC #560, #569)", .{chain});
                    return error.PrefabCycle;
                },
                error.DepthExceeded => return error.IncludeDepthExceeded,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        // ── Public entry points ────────────────────────────────

        /// Load a JSONC scene file and instantiate all entities in the ECS.
        pub fn loadScene(game: *GameType, scene_path: []const u8, prefab_dir: []const u8) !void {
            // Reuse any existing cache so prefabs registered via
            // `addEmbeddedPrefab` before `loadScene` runs survive
            // — same failure mode as `loadSceneFromSource`, just
            // less commonly hit because filesystem-based
            // `loadScene` is a desktop path.
            const prefab_cache = try prefab_cache_mod.getOrCreatePrefabCache(game, prefab_dir);

            // Eagerly populate the flat name-keyed registry from the
            // filesystem (RFC #560, #561): recursively scan the
            // project's `prefabs/` and sibling `scenes/` directories
            // up-front. This resolves files whose `"name"` diverges
            // from their basename and catches cross-file effective-
            // name collisions as a hard load-time error. Desktop-only
            // — no-op on WASM/mobile, where there is no filesystem
            // and prefabs/scenes arrive via the assembler-emitted
            // embedded sources / `addEmbeddedPrefab`.
            try prefab_cache_mod.scanRegistry(prefab_cache, game.log, prefab_dir);

            try loadSceneFile(game, scene_path, prefab_cache, 0);

            // Enable runtime prefab spawning.
            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Load a scene from an in-memory JSONC source string (for
        /// embedded/release builds). The source must outlive the
        /// loaded scene — typically a comptime `@embedFile` slice.
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
            //     `addEmbeddedPrefab` itself
            // ================================================================
            const prefab_cache = try prefab_cache_mod.getOrCreatePrefabCache(game, prefab_dir);

            try loadSceneSource(game, source, prefab_cache);

            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &spawnPrefabImpl;
        }

        /// Pre-load a prefab from in-memory JSONC source into the
        /// persistent cache. Call before `loadSceneFromSource` so
        /// the prefab is available without file I/O.
        ///
        /// The cache key is the prefab's *effective name* — its
        /// `"name"` field when present, else the `name` argument
        /// (which the assembler passes as the file basename). This
        /// is the flat name-keyed registry of RFC #561: a prefab
        /// resolves by the same name regardless of its filename or
        /// which directory it lives in.
        ///
        /// A duplicate effective name is a load-time error
        /// (`error.DuplicatePrefabName`) — there is no precedence
        /// rule; the author renames a file or sets a distinct
        /// `"name"`. The assembler emits one call per prefab, so a
        /// collision here means two source files genuinely clash.
        pub fn addEmbeddedPrefab(game: *GameType, name: []const u8, source: []const u8, prefab_dir: []const u8) !void {
            const prefab_cache = try prefab_cache_mod.getOrCreatePrefabCache(game, prefab_dir);

            const persistent = prefab_cache.persistent;
            var parser = JsoncParser.init(persistent, source);
            const val = try parser.parse();

            const key = if (val.asObject()) |obj| uf.effectiveName(obj, name) else name;
            if (prefab_cache.prefabs.contains(key)) {
                game.log.err("[registry] duplicate prefab name '{s}': rename the file or give one a distinct \"name\" (RFC #561)", .{key});
                return error.DuplicatePrefabName;
            }
            const duped_key = try persistent.dupe(u8, key);
            errdefer persistent.free(duped_key);
            try prefab_cache.prefabs.put(duped_key, val);
        }

        // ── Runtime prefab spawn ───────────────────────────────

        /// Runtime prefab instantiation — creates an entity from a
        /// named prefab. Wired into `game.spawn_prefab_fn` by the
        /// public load entry points.
        pub fn spawnPrefabImpl(game: *GameType, name: []const u8, pos: Position) ?Entity {
            const cache_ptr = game.prefab_cache_ptr orelse return null;
            var prefab_cache = @as(*PrefabCache, @ptrCast(@alignCast(cache_ptr)));
            const prefab_val = prefab_cache.get(name) orelse {
                const prefab_dir = game.prefab_dir orelse "?";
                game.log.err("[spawnPrefab] Prefab '{s}' not found in '{s}'", .{ name, prefab_dir });
                return null;
            };
            const prefab_obj = prefab_val.asObject() orelse return null;
            const prefab_root = uf.rootObject(prefab_obj);

            // Cycle gate. Walk a synthetic reference entry so the
            // shared walker pushes `name` onto its expansion stack
            // — that way a prefab that references itself (directly
            // or via a child / nested component field) is caught
            // (RFC #569). On a cycle the chain is logged and the
            // spawn fails (`null`) rather than recursing forever.
            //
            // Run UNCONDITIONALLY, before the `components` lookup
            // below: a cyclic prefab whose `root` has no `components`
            // (the cycle lives purely in `root.children`) would
            // otherwise bypass the diagnostic via the early `return
            // null` and just silently fail to spawn.
            {
                var ref_entries = [_]Value.Object.Entry{
                    .{ .key = "prefab", .value = .{ .string = name } },
                };
                const ref_entry = Value{ .object = .{ .entries = &ref_entries } };
                var cycle_ctx = tree_walker.WalkContext.init(game.allocator);
                defer cycle_ctx.deinit();
                checkEntityTreeCycles(game, ref_entry, prefab_cache, &cycle_ctx) catch |err| {
                    game.log.err("[spawnPrefab] '{s}' not spawned: {s}", .{ name, @errorName(err) });
                    return null;
                };
            }

            const prefab_components = prefab_root.getObject("components") orelse return null;

            const entity = game.createEntity();
            game.trackSceneEntity(entity);
            game.setPosition(entity, pos);

            // Apply all prefab components — use pos as
            // parent_offset so prefab positions are relative to the
            // spawn point.
            for (prefab_components.entries) |entry| {
                ApplyHelpers.applyComponent(game, entity, entry.key, entry.value, pos);
            }

            // Handle nested entities (e.g. workstation storages).
            const entity_pos = game.getPosition(entity);
            for (prefab_components.entries) |entry| {
                spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, 0, null);
            }

            // Fire onReady hooks.
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();
            // No scene/override components here — `is_reference` is
            // moot (the scene loop is skipped on a null block).
            OnReadyHelpers.fireOnReadyAll(game, entity, null, prefab_components, &applied, false);

            // Process children — save world pos, set parent, restore (#417).
            if (prefab_root.getArray("children")) |children| {
                for (children.items) |child_val| {
                    const child = loadEntityInternal(game, child_val, prefab_cache, 1, entity_pos, null) catch continue;
                    const world_pos = game.getPosition(child);
                    game.setParent(child, entity, .{});
                    game.setWorldPosition(child, world_pos);
                }
            }

            return entity;
        }

        // ── Top-level scene processing ─────────────────────────

        /// Process entities from a parsed scene, with two-pass ref
        /// resolution.
        fn processEntities(game: *GameType, entities_arr: Value.Array, prefab_cache: *PrefabCache, ref_ctx: *RefContext) LoadEntityError!void {
            // Pass 0: cycle gate. The shared tree-walker crosses
            // both `children` and prefab refs nested in component
            // fields, so a cycle hidden in either path is caught
            // before any entity is created (RFC #569).
            //
            // One `WalkContext` for the whole scene: its expansion
            // stack and diagnostic buffer keep their capacity across
            // entries, so a scene with N top-level entities does N
            // walks but only one set of ArrayList growths.
            var cycle_ctx = tree_walker.WalkContext.init(game.allocator);
            defer cycle_ctx.deinit();
            for (entities_arr.items) |entity_val| {
                cycle_ctx.stack.clearRetainingCapacity();
                cycle_ctx.cycle_chain.clearRetainingCapacity();
                try checkEntityTreeCycles(game, entity_val, prefab_cache, &cycle_ctx);
            }

            // Pass 1: create entities, apply components (with
            // `@ref` → 0), collect refs.
            for (entities_arr.items) |entity_val| {
                _ = try loadEntityInternal(game, entity_val, prefab_cache, 0, .{ .x = 0, .y = 0 }, ref_ctx);
            }

            // Pass 2: patch `@ref` fields with resolved entity IDs.
            for (ref_ctx.deferred.items) |deferred| {
                RefResolver.patchRefField(game, deferred, ref_ctx);
            }
        }

        /// Load a single scene/fragment file, processing includes
        /// recursively then its own entities.
        ///
        /// Source resolution: check `game.embedded_scene_sources` first
        /// (populated by the assembler-generated `addEmbeddedSceneSource`
        /// calls — the only mechanism that works on WASM/Android where
        /// the project directory isn't reachable from cwd), then fall
        /// back to `std.fs.cwd().openFile(path)` for desktop dev runs.
        /// Mirrors the embedded-first ordering established by
        /// `PrefabCache.get` for prefabs.
        fn loadSceneFile(game: *GameType, path: []const u8, prefab_cache: *PrefabCache, include_depth: usize) !void {
            if (include_depth > MAX_DEPTH) return error.IncludeDepthExceeded;

            // Use an arena for the scene parser — the source
            // buffer and parsed `Value` tree (entries/items
            // slices) are only needed during entity processing
            // and can be freed together afterwards.
            var parse_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer parse_arena.deinit();
            const parse_alloc = parse_arena.allocator();

            const source: []const u8 = if (game.embedded_scene_sources.get(path)) |embedded|
                embedded
            else
                try std.Io.Dir.cwd().readFileAlloc(io_helper.io(), path, parse_alloc, .limited(1024 * 1024));

            var parser = JsoncParser.init(parse_alloc, source);
            const scene_value = try parser.parse();

            const scene_obj = scene_value.asObject() orelse return;

            // Process includes first — their entities are created
            // before this file's own entities.
            if (scene_obj.getArray("include")) |include_arr| {
                for (include_arr.items) |include_val| {
                    const include_path = include_val.asString() orelse continue;
                    try loadSceneFile(game, include_path, prefab_cache, include_depth + 1);
                }
            }

            // Process this file's entities with ref support.
            // `fileChildren` accepts the unified `root.children`
            // shape and the legacy top-level `entities` array.
            uf.warnLegacyAssets(scene_obj, game.log);
            // RFC #560 §B2 at the file root: a reference-mode root
            // (`"root": { "prefab": ..., ... }`) may not declare
            // `"children"` — instantiating doesn't author. See
            // RFC-UNIFY-SCENES-AND-PREFABS.md §Unified shape.
            if (scene_obj.getObject("root")) |root_obj| {
                try uf.rejectB2Violation(root_obj, game.log, "reference-mode root");
            }
            if (uf.fileChildren(scene_obj, game.log)) |entities_arr| {
                var ref_ctx = RefContext.init(game.allocator, null);
                defer ref_ctx.deinit();
                try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
            }
        }

        /// Load a scene from an in-memory source string (no file
        /// I/O). Includes still load from disk if present in the
        /// scene. Note: duplicates parse/entity logic from
        /// `loadSceneFile` because Zig cannot resolve inferred
        /// error sets with mutual recursion.
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

            uf.warnLegacyAssets(scene_obj, game.log);
            // RFC #560 §B2 at the file root: a reference-mode root
            // (`"root": { "prefab": ..., ... }`) may not declare
            // `"children"` — instantiating doesn't author. See
            // RFC-UNIFY-SCENES-AND-PREFABS.md §Unified shape.
            if (scene_obj.getObject("root")) |root_obj| {
                try uf.rejectB2Violation(root_obj, game.log, "reference-mode root");
            }
            if (uf.fileChildren(scene_obj, game.log)) |entities_arr| {
                var ref_ctx = RefContext.init(game.allocator, null);
                defer ref_ctx.deinit();
                try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
            }
        }

        // ── Entity-tree walker ─────────────────────────────────

        /// Unified entity loader — handles top-level and child
        /// entities, with optional ref context for `@ref`
        /// cross-reference support.
        ///
        /// When `ref_ctx` is non-null, registers `ref` names and
        /// applies components with `@ref` strings replaced by `0`
        /// (patched in pass 2). When `ref_ctx` is null, follows the
        /// original single-pass path.
        fn loadEntityInternal(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position, ref_ctx: ?*RefContext) LoadEntityError!Entity {
            if (depth > MAX_DEPTH) return error.IncludeDepthExceeded;
            const entity_obj = entity_val.asObject() orelse return error.InvalidFormat;

            // RFC #560 §B2: reference-mode entries (those carrying a
            // `"prefab"` field) may not also declare a `"children"`
            // array — references instantiate, they do not author.
            // Reject at every child-entry visit so a violation deep
            // in a nested tree still surfaces as a load-time error
            // rather than silent acceptance with the children
            // ignored. See labelle-assembler#182 for the pre-build
            // companion check (this is defense-in-depth for embedded
            // sources, hand-edited save files, and third-party tools).
            try uf.rejectB2Violation(entity_obj, game.log, "child entry");

            // Resolve prefab.
            var prefab_components: ?Value.Object = null;
            var prefab_children: ?Value.Array = null;
            var prefab_obj_opt: ?Value.Object = null;
            if (entity_obj.getString("prefab")) |prefab_name| {
                if (prefab_cache.get(prefab_name)) |prefab_val| {
                    if (prefab_val.asObject()) |pobj| {
                        prefab_obj_opt = pobj;
                        // Unwrap the unified `root` block (a no-op
                        // on legacy prefabs that lack it).
                        const proot = uf.rootObject(pobj);
                        prefab_components = proot.getObject("components");
                        prefab_children = proot.getArray("children");
                    }
                }
            }

            // For a reference entry this is the `overrides` patch;
            // for an inline entry, its own `components`.
            const scene_components = uf.entityPatch(entity_obj, game.log);

            // `null`-as-removal is scoped to reference entries'
            // `overrides` (RFC #562) — an inline entity's
            // `components` have no removal semantics.
            const is_reference = entity_obj.getString("prefab") != null;

            // Create entity — destroy on error to prevent orphans.
            const entity = game.createEntity();
            game.trackSceneEntity(entity);
            errdefer game.destroyEntity(entity);

            // Register ref name if ref context is active.
            // Scene-level ref overrides prefab-level ref.
            // `@ref` is scoped to a single scene file — refs from
            // included files are not visible (each file gets its
            // own RefContext).
            if (ref_ctx) |rctx| {
                const entity_id: u64 = @intCast(entity);
                const ref_name = entity_obj.getString("ref") orelse
                    if (prefab_obj_opt) |pobj| uf.rootObject(pobj).getString("ref") else null;
                if (ref_name) |rn| {
                    if (try rctx.ref_map.fetchPut(rn, entity_id)) |existing| {
                        game.log.warn("[SceneRef] Duplicate ref '{s}' (entities {d} and {d})", .{ rn, existing.value, entity_id });
                    }
                }
            }

            // Build the entity's component set: prefab defaults
            // patched by the reference entry's `overrides`. An
            // override deep-merges onto the prefab's same-named
            // component — patching only the fields it names — and a
            // `null` override removes the component (RFC #562).
            //
            // The merge tree lives in `merge_arena`; its leaf
            // strings are shared with the prefab/override inputs, so
            // `@ref` names collected from a merged component stay
            // valid into the pass-2 patch even after the arena frees.
            var merge_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer merge_arena.deinit();

            // `applied` records every override key — including
            // `null` removals — so the prefab blocks below skip them.
            var applied = std.StringHashMap(void).init(game.allocator);
            defer applied.deinit();

            // Precompute the effective (merged) value for each override
            // entry once, in `merge_arena`, so the apply-component and
            // spawn-nested-entity passes share the same merged tree
            // instead of redoing the deep-merge per pass. `null`
            // entries here mark removals that both passes must skip
            // in lockstep.
            const effective_overrides: ?[]?Value = if (scene_components) |sc| blk: {
                const slice = try merge_arena.allocator().alloc(?Value, sc.entries.len);
                for (sc.entries, 0..) |entry, i| {
                    if (is_reference and entry.value == .null_value) {
                        slice[i] = null;
                    } else {
                        slice[i] = try uf.mergedOverride(prefab_components, entry.key, entry.value, merge_arena.allocator());
                    }
                }
                break :blk slice;
            } else null;

            // Apply scene/override components, each deep-merged over
            // the prefab's matching component.
            if (scene_components) |sc| {
                for (sc.entries, 0..) |entry, i| {
                    try applied.put(entry.key, {});
                    // A `null` override removes a component, but only
                    // for a reference entry's `overrides`. An inline
                    // entity's `components` carry no removal meaning
                    // — a `null` there is just a (likely malformed)
                    // value, not a deletion.
                    const effective = effective_overrides.?[i] orelse continue; // removal
                    try ApplyHelpers.applyComponentWithRefs(game, entity, entry.key, effective, parent_offset, ref_ctx);
                }
            }

            // Apply prefab components the override did not touch.
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        try ApplyHelpers.applyComponentWithRefs(game, entity, entry.key, entry.value, parent_offset, ref_ctx);
                    }
                }
            }

            // Get this entity's world position for offsetting
            // nested children.
            const entity_pos = game.getPosition(entity);

            // Spawn nested entity arrays and collect IDs to patch
            // back into components. Reuses `effective_overrides`
            // computed above — a deep-merged component keeps the
            // prefab's entity-bearing fields, so their nested
            // entities must still spawn.
            if (scene_components) |sc| {
                for (sc.entries, 0..) |entry, i| {
                    const effective = effective_overrides.?[i] orelse continue;
                    spawnAndLinkNestedEntities(game, entity, entry.key, effective, entity_pos, prefab_cache, depth, ref_ctx);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth, ref_ctx);
                    }
                }
            }

            // Fire onReady for all applied components (after entity
            // is fully assembled).
            OnReadyHelpers.fireOnReadyAll(game, entity, scene_components, prefab_components, &applied, is_reference);

            // Process children recursively (prefab children +
            // entity-level children).
            //
            // `loadEntityInternal` already applied `parent_offset`
            // to the child's `Position` (world coords). `setParent`
            // would double-offset via `computeWorldTransform`, so
            // we save the world pos, set parent, then restore it
            // (#417).
            //
            // When a child is itself a prefab instance, it gets
            // its own local `RefContext` so prefab-internal refs
            // (e.g. `ref: "storage"` inside
            // `food_storage_with_packet`) don't collide across
            // sibling instances of the same prefab. This mirrors
            // the pattern already used by
            // `spawnAndLinkNestedEntities` for entities nested
            // inside component array fields. See engine #425 /
            // flying-platform #53.
            //
            // Plain children (no `prefab` key) keep using the
            // parent's `ref_ctx` so scene-level cross-references
            // between top-level entities still work as before.
            if (prefab_children) |children| {
                for (children.items) |child_val| {
                    try loadChildEntity(game, entity, child_val, prefab_cache, depth, entity_pos, ref_ctx);
                }
            }

            // Save/load: tag prefab-sourced entities with
            // `PrefabInstance` (root) + `PrefabChild` (each
            // descendant) so the save mixin records their prefab
            // origin and the two-phase load can respawn the prefab
            // + remap saved child IDs to the newly-spawned
            // descendants via `(root, local_path)`. Uses the
            // shared `game.tagAsPrefabInstance` so the
            // `local_path` format stays identical to the runtime
            // `spawnFromPrefab` path — save mixin's
            // `findChildByLocalPath` can match either.
            //
            // Tag BEFORE scene-declared children are attached. If
            // a scene over-declares children on top of a prefab
            // (e.g. the scene adds decorations around a
            // prefab-sourced room), those scene-only children must
            // NOT get `PrefabChild` markers — they don't belong to
            // the prefab definition, and on load Phase 1b would
            // otherwise walk `children[N]` and either miss
            // (prefab grew fewer children than saved) or mis-map
            // onto a newly-added prefab child at the same index
            // (prefab evolved). Propagate the error via `try`
            // instead of logging and continuing: an untagged
            // prefab root is invisible to Phase 1a, so a silent
            // failure breaks F5 → F9 round-trip. `LoadEntityError`
            // already carries `OutOfMemory`.
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

        /// Load a single child entity and attach it to its parent.
        /// Handles the per-instance ref-scoping wrapper when the
        /// child is itself a prefab instance — see the comment in
        /// the caller for the rationale.
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
                // Per-instance ref scope for prefab children.
                // Chained to the parent scope so a prefab-body
                // entity can still resolve refs declared in an
                // enclosing scope (e.g. `food_packet` inside
                // `food_storage_with_packet` looking up its
                // parent's `@storage`). Registrations stay local
                // so repeated sibling instances of the same prefab
                // don't collide on their internal ref names.
                var local_ctx = RefContext.init(game.allocator, ref_ctx);
                defer local_ctx.deinit();

                const c = try loadEntityInternal(game, child_val, prefab_cache, depth + 1, parent_pos, &local_ctx);

                // If the child was given a scene-level ref
                // override, bubble it up to the parent scope so
                // siblings and the parent entity can reference
                // this child. Prefab-internal refs stay local.
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

                // Patch deferred refs collected inside the local
                // context. Lookups walk up the parent chain, so
                // refs that point at an ancestor scope (e.g.
                // `@storage` inside a nested prefab body) resolve
                // correctly.
                for (local_ctx.deferred.items) |deferred| {
                    RefResolver.patchRefField(game, deferred, &local_ctx);
                }

                break :blk c;
            } else
                // Plain child: uses the parent's `ref_ctx` so
                // scene-level cross-references still work.
                try loadEntityInternal(game, child_val, prefab_cache, depth + 1, parent_pos, ref_ctx);

            // Save world pos before setParent to avoid
            // double-offset (#417).
            const world_pos = game.getPosition(child);
            game.setParent(child, parent_entity, .{});
            game.setWorldPosition(child, world_pos);
        }

        // ── Nested-entity spawn (component array fields) ───────

        /// Spawn entity-like objects nested inside a component's
        /// fields, collect their entity IDs, and patch them back
        /// into the component's `[]const u64` fields.
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

            // Arena for deep-merged override component values
            // (RFC #562) — mirrors the block in `loadEntityInternal`.
            var merge_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer merge_arena.deinit();

            for (obj.entries) |entry| {
                const arr = entry.value.asArray() orelse continue;

                // Count entity-like items.
                var entity_count: usize = 0;
                for (arr.items) |item| {
                    if (ApplyHelpers.isEntityLike(item)) entity_count += 1;
                }
                if (entity_count == 0) continue;

                // Spawn entities and collect IDs. Uses
                // `persistent_id_allocator` (page_allocator on
                // desktop, c_allocator on wasm32-emscripten — see
                // file-top comment) because IDs are stored in
                // component fields (`[]const u64`) and live for
                // the game's lifetime.
                const ids = persistent_id_allocator.alloc(u64, entity_count) catch continue;
                var idx: usize = 0;
                for (arr.items) |item| {
                    if (ApplyHelpers.isEntityLike(item)) {
                        const child = game.createEntity();
                        game.trackSceneEntity(child);

                        if (item.asObject()) |child_obj| {
                            var child_prefab_comps: ?Value.Object = null;
                            var child_prefab_children: ?Value.Array = null;
                            if (child_obj.getString("prefab")) |pname| {
                                if (prefab_cache.get(pname)) |pval| {
                                    if (pval.asObject()) |pobj| {
                                        const proot = uf.rootObject(pobj);
                                        child_prefab_comps = proot.getObject("components");
                                        child_prefab_children = proot.getArray("children");
                                    }
                                }
                            }

                            // Register scene-level ref in the
                            // parent's ref context. Only explicit
                            // `ref` on the nested entity (not
                            // from the prefab) goes into the
                            // parent scope — prefab-internal refs
                            // are scoped per-instance below to
                            // avoid collisions between repeated
                            // prefabs.
                            if (ref_ctx) |rctx| {
                                if (child_obj.getString("ref")) |rn| {
                                    const entity_id: u64 = @intCast(child);
                                    if (rctx.ref_map.fetchPut(rn, entity_id) catch null) |existing| {
                                        game.log.warn("[SceneRef] Duplicate ref '{s}' (entities {d} and {d})", .{ rn, existing.value, entity_id });
                                    }
                                }
                            }

                            // Use a local `RefContext` for this
                            // nested entity's children so that
                            // prefab-internal refs (e.g.
                            // `@storage`/`@item` in
                            // `eis_with_water`) are scoped
                            // per-instance and don't collide
                            // across repeated prefabs. Chained to
                            // the caller's `ref_ctx` so prefab
                            // bodies can still resolve refs from
                            // enclosing scopes via parent-chain
                            // lookup.
                            var local_ref_ctx = RefContext.init(game.allocator, ref_ctx);
                            defer local_ref_ctx.deinit();
                            const nested_ref_ctx: *RefContext = &local_ref_ctx;

                            // Register the nested entity in the
                            // local context so its children can
                            // reference it via `@ref`. Always
                            // register the prefab-defined ref
                            // (for internal `@ref`s like
                            // `@storage`), plus the scene-level
                            // ref if different (as an alias).
                            {
                                const entity_id: u64 = @intCast(child);
                                const scene_ref = child_obj.getString("ref");
                                var prefab_ref: ?[]const u8 = null;
                                if (child_obj.getString("prefab")) |pname| {
                                    if (prefab_cache.get(pname)) |pval| {
                                        if (pval.asObject()) |pobj| {
                                            prefab_ref = uf.rootObject(pobj).getString("ref");
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

                            // Reference entry → `overrides`; inline → `components`.
                            const child_scene_comps = uf.entityPatch(child_obj, game.log);

                            // `null`-as-removal is scoped to a
                            // reference entry's `overrides` (RFC #562).
                            const child_is_reference = child_obj.getString("prefab") != null;

                            // Precompute the effective (merged) value
                            // for each override entry once, in
                            // `merge_arena`, so the apply-component
                            // and recurse-nested-entity passes share
                            // the same merged tree. `null` slots mark
                            // removals or merge failures both passes
                            // must skip in lockstep.
                            const child_effective: ?[]?Value = if (child_scene_comps) |sc| blk: {
                                const slice = merge_arena.allocator().alloc(?Value, sc.entries.len) catch break :blk null;
                                for (sc.entries, 0..) |e, i| {
                                    if (child_is_reference and e.value == .null_value) {
                                        slice[i] = null;
                                    } else if (uf.mergedOverride(child_prefab_comps, e.key, e.value, merge_arena.allocator())) |eff| {
                                        slice[i] = eff;
                                    } else |err| {
                                        game.log.err("[NestedEntity] Failed to merge override {s}: {s}", .{ e.key, @errorName(err) });
                                        slice[i] = null;
                                    }
                                }
                                break :blk slice;
                            } else null;

                            // Override components first, each
                            // deep-merged over the prefab's match;
                            // a `null` override removes it (#562).
                            if (child_scene_comps) |sc| {
                                for (sc.entries, 0..) |e, i| {
                                    // `null`-as-removal applies only
                                    // to a reference entry's
                                    // `overrides` (RFC #562). A null
                                    // slot here also covers merge
                                    // failures already logged above.
                                    const effective = (child_effective orelse break)[i] orelse continue;
                                    ApplyHelpers.applyComponentWithRefs(game, child, e.key, effective, parent_world_pos, nested_ref_ctx) catch |err| {
                                        game.log.err("[NestedEntity] Failed to apply {s}: {s}", .{ e.key, @errorName(err) });
                                    };
                                }
                            }
                            // Prefab defaults.
                            if (child_prefab_comps) |pc| {
                                for (pc.entries) |e| {
                                    const already_set = if (child_scene_comps) |sc| blk: {
                                        for (sc.entries) |se| {
                                            if (std.mem.eql(u8, se.key, e.key)) break :blk true;
                                        }
                                        break :blk false;
                                    } else false;
                                    if (!already_set) {
                                        ApplyHelpers.applyComponentWithRefs(game, child, e.key, e.value, parent_world_pos, nested_ref_ctx) catch |err| {
                                            game.log.err("[NestedEntity] Failed to apply {s}: {s}", .{ e.key, @errorName(err) });
                                        };
                                    }
                                }
                            }

                            // Recursively spawn nested entities
                            // inside this child's components. Reuses
                            // `child_effective` from the apply pass.
                            const child_pos = game.getPosition(child);
                            if (child_scene_comps) |sc| {
                                for (sc.entries, 0..) |e, i| {
                                    const effective = (child_effective orelse break)[i] orelse continue;
                                    spawnAndLinkNestedEntities(game, child, e.key, effective, child_pos, prefab_cache, depth + 1, nested_ref_ctx);
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

                            // Process children (prefab children +
                            // inline children) (#415).
                            // Save world pos before setParent to
                            // avoid double-offset (#417).
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

                            // Patch deferred refs from the local
                            // context. Lookups walk up the parent
                            // chain to resolve refs that point at
                            // an enclosing scope.
                            for (local_ref_ctx.deferred.items) |deferred| {
                                RefResolver.patchRefField(game, deferred, &local_ref_ctx);
                            }

                            // Fire onReady + postLoad for this
                            // nested child now that its
                            // components, nested entities, and
                            // refs are all in place. Parity with
                            // the top-level `fireOnReadyAll` in
                            // `loadEntityInternal` — without
                            // this, components declared on nested
                            // entities (e.g. `Workstation.postLoad`
                            // inside a Room's `workstations`
                            // array) never run.
                            //
                            // Pre-populate `applied` with scene
                            // component names so
                            // `fireOnReadyAll`'s prefab-loop
                            // `contains` check skips prefab
                            // entries that the scene already
                            // overrode. Otherwise any component
                            // present in BOTH maps would fire its
                            // hooks twice (once from the scene
                            // loop, once from the prefab loop).
                            var nested_applied = std.StringHashMap(void).init(game.allocator);
                            defer nested_applied.deinit();
                            if (child_scene_comps) |sc| {
                                for (sc.entries) |e| {
                                    nested_applied.put(e.key, {}) catch {};
                                }
                            }
                            OnReadyHelpers.fireOnReadyAll(game, child, child_scene_comps, child_prefab_comps, &nested_applied, child_is_reference);
                        }

                        ids[idx] = @intCast(child);
                        idx += 1;
                    }
                }

                // Patch the entity ID array back into the parent
                // component.
                OnReadyHelpers.patchEntityIdField(game, parent_entity, comp_name, entry.key, ids);

                // Register nested entities as children for
                // cascade destruction.
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
    };
}
