//! Top-level scene processing + public entry points.
//!
//! Extracted from `scene_loader.zig` (slice of the <1000-line split).
//! Holds the public load API (`loadScene`, `loadSceneFromSource`,
//! `addEmbeddedPrefab`), the file-header `meta:` directive handling,
//! the two-pass `@ref` resolution driver (`processEntities`), and the
//! file/source ingestion entry points. Calls back into the parent
//! loader (`Self`) for cycle gating, entity loading, and the runtime
//! spawn function pointer. Behavior is identical to the inlined
//! version — only the source location moved.

const std = @import("std");
const io_helper = @import("../../io_helper.zig");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;

const prefab_cache_mod = @import("../prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const uf = @import("../unified_format.zig");
const tree_walker = @import("../tree_walker.zig");
const ref_resolver_mod = @import("../ref_resolver.zig");

pub fn SceneProcess(comptime GameType: type, comptime Components: type, comptime Self: type) type {
    const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
    const RefContext = RefResolver.RefContext;

    return struct {
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
            game.spawn_prefab_fn = &Self.spawnPrefabImpl;
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

            // Runtime scene-source override (labelle-studio Play mode /
            // editor_api). This entry point receives bytes, not a name,
            // so the scene identity comes from `game.loading_scene_name`
            // — set by `setScene`/`setSceneAtomic`/hot-reload around the
            // registered loader call. When the editor has stored an
            // override for that scene, it replaces the embedded source.
            const effective_source: []const u8 = if (game.loading_scene_name) |scene_name|
                (game.sceneSourceOverride(scene_name) orelse source)
            else
                source;

            try loadSceneSource(game, effective_source, prefab_cache);

            game.prefab_dir = prefab_dir;
            game.spawn_prefab_fn = &Self.spawnPrefabImpl;
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

        // ── Top-level scene processing ─────────────────────────

        /// Apply engine-known directives from a bundle file-header
        /// `meta:` block (RFC #596). Today the only consumed key is
        /// `initial_state` — `meta.initial_state: "<state>"` switches
        /// the game's state machine to `<state>` BEFORE entities are
        /// spawned, so state-gated scripts see the right state on the
        /// first tick after the load.
        ///
        /// All other lowercase keys (`name`, `author`, `draft`, …) are
        /// authoring-only and ignored silently — they're free-form
        /// metadata for tools, not engine directives. `meta.scripts`
        /// and `meta.include` are reserved by the RFC but currently
        /// unused; once a consumer lands they'd join this dispatch.
        ///
        /// A non-object `meta:` value (e.g. `meta: "label"`) is also
        /// ignored — the RFC documents `meta:` as a structured block,
        /// but the loader doesn't error on malformed shapes here
        /// because audit/tooling has a clearer error surface.
        fn applyFileMetaDirectives(game: *GameType, file_meta: ?Value) void {
            const meta_val = file_meta orelse return;
            const meta_obj = meta_val.asObject() orelse return;
            if (meta_obj.getString("initial_state")) |state_name| {
                if (!std.mem.eql(u8, game.game_state, state_name)) {
                    game.log.info("[scene] file-header meta.initial_state '{s}' → '{s}' (RFC #596)", .{ game.game_state, state_name });
                }
                // `state_name` aliases into the loader's `parse_arena`,
                // which is freed in the `defer` at the top of
                // `loadSceneFile` / `loadSceneSource` before the load
                // function returns. `setState` (see `state_mixin.zig`)
                // stores its argument by reference into `game.game_state`,
                // so handing the arena-slice in directly would leave
                // `game_state` dangling after the arena teardown.
                //
                // Dupe onto `game.allocator` and stash the owned backing
                // on `game.owned_initial_state` so it lives as long as
                // `game_state` itself.
                //
                // PR #599 history (three fixes):
                //
                //  Fix #1: dupe meta.initial_state so the slice survives
                //          parse_arena.deinit (first-order UAF).
                //
                //  Fix #2: reorder dupe/setState/free so the prior owned
                //          slot is still live while setState's
                //          `std.mem.eql(self.game_state, …)` probe runs
                //          (second-order UAF when game.game_state aliased
                //          the slot we'd just freed).
                //
                //  Fix #3 (here): drop the no-churn short-circuit that
                //          fix #2 added. The short-circuit
                //          `if (existing == state_name content) return;`
                //          assumed `game.game_state` still aliased the
                //          owned slot — but an external `setState(...)`
                //          call between two `applyFileMetaDirectives`
                //          invocations could have re-pointed
                //          `game.game_state` elsewhere, leaving the
                //          directive silently ignored (cursor MEDIUM:
                //          game stayed in the wrong state).
                //
                // The new contract: always dupe, always free the prior.
                // The dupe + free churn per scene load is negligible
                // compared to the bug surface of a clever short-circuit.
                //
                // Ordering (preserves fix #2's UAF guarantee):
                //
                //   1. Dupe onto the game allocator — `new_owned`.
                //   2. Swap `owned_initial_state` to the fresh dupe
                //      *before* `setState`. The field is consistent even
                //      if `setState` early-returns.
                //   3. `setState(new_owned)`. Its `eql` probe reads
                //      `game.game_state`, which still aliases the prior
                //      owned slot (still live) or a default literal.
                //      Safe either way.
                //   4. If `setState` short-circuited (because
                //      `game.game_state` already content-equalled
                //      `state_name`), `game.game_state` may still alias
                //      the about-to-be-freed `old_owned`. Detect that
                //      via pointer identity against `new_owned` and
                //      explicitly re-point. Doing this only when the
                //      pointer doesn't already match `new_owned` skips
                //      the safe re-assign in the literal-aliasing case
                //      where re-pointing to `new_owned` is also fine
                //      (we just don't need to bother).
                //
                //      We do NOT re-fire state-change hooks here —
                //      that's correct: the visible state value is
                //      unchanged, we're only refreshing the backing
                //      pointer.
                //   5. Free the previous owned slot (no-op if null).
                const new_owned = game.allocator.dupe(u8, state_name) catch {
                    // Out of memory — keep the previous state rather than
                    // crash the load. The directive is best-effort.
                    return;
                };
                const old_owned = game.owned_initial_state;
                game.owned_initial_state = new_owned;
                game.setState(new_owned);
                if (game.game_state.ptr != new_owned.ptr) {
                    // setState short-circuited: game.game_state still
                    // points at whatever it pointed at before (a literal
                    // or, critically, `old_owned`). Re-point to
                    // `new_owned` so the upcoming `free(old_owned)`
                    // doesn't dangle game.game_state. Safe in the
                    // literal-alias case too — the literal stays valid,
                    // we just stop referencing it.
                    game.game_state = new_owned;
                }
                if (old_owned) |s| game.allocator.free(s);
            }
            // Future engine-known keys (`scripts`, `include`) dispatch here.
            // `name` and any other lowercase keys are authoring-only.
        }

        /// Process entities from a parsed scene, with two-pass ref
        /// resolution.
        fn processEntities(game: *GameType, entities_arr: Value.Array, prefab_cache: *PrefabCache, ref_ctx: *RefContext) Self.LoadEntityError!void {
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
                try Self.checkEntityTreeCycles(game, entity_val, prefab_cache, &cycle_ctx);
            }

            // Pass 1: create entities, apply components (with
            // `@ref` → 0), collect refs.
            for (entities_arr.items) |entity_val| {
                _ = try Self.loadEntityInternal(game, entity_val, prefab_cache, 0, .{ .x = 0, .y = 0 }, ref_ctx);
            }

            // Pass 2: patch `@ref` fields with resolved entity IDs.
            for (ref_ctx.deferred.items) |deferred| {
                RefResolver.patchRefField(game, deferred, ref_ctx);
            }
        }

        /// Load a single scene/fragment file, processing includes
        /// recursively then its own entities.
        ///
        /// Source resolution: check `game.scene_source_overrides` first
        /// (runtime overrides stored by the labelle-studio editor via
        /// `editor_api.editor_load_scene`), then
        /// `game.embedded_scene_sources` (populated by the
        /// assembler-generated `addEmbeddedSceneSource` calls — the only
        /// mechanism that works on WASM/Android where the project
        /// directory isn't reachable from cwd), then fall back to
        /// `std.fs.cwd().openFile(path)` for desktop dev runs.
        /// Mirrors the embedded-first ordering established by
        /// `PrefabCache.get` for prefabs.
        fn loadSceneFile(game: *GameType, path: []const u8, prefab_cache: *PrefabCache, include_depth: usize) !void {
            if (include_depth > Self.MAX_DEPTH) return error.IncludeDepthExceeded;

            // Use an arena for the scene parser — the source
            // buffer and parsed `Value` tree (entries/items
            // slices) are only needed during entity processing
            // and can be freed together afterwards.
            var parse_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer parse_arena.deinit();
            const parse_alloc = parse_arena.allocator();

            const source: []const u8 = if (game.sceneSourceOverride(path)) |override|
                // Runtime override (labelle-studio Play mode / editor_api)
                // outranks both the embedded source and the filesystem —
                // matched by exact path first, then by the path's stem
                // (an override stored under `"frag"` replaces
                // `"scenes/frag.jsonc"`).
                override
            else if (game.embedded_scene_sources.get(path)) |embedded|
                embedded
            else
                try std.Io.Dir.cwd().readFileAlloc(io_helper.io(), path, parse_alloc, .limited(1024 * 1024));

            var parser = JsoncParser.init(parse_alloc, source);
            const scene_value = try parser.parse();

            // RFC #596 Axis 3: a top-level Array is a bundle of
            // sibling entities (no implicit root). The optional
            // header (`{ meta: ... }` at index 0) is dropped here —
            // tools can re-parse the file for `meta`, the runtime
            // never reads it. Object top-level rides the existing
            // single-root pipeline.
            const top = uf.classifyTopLevel(scene_value) orelse return error.InvalidFormat;
            switch (top) {
                .single_root => |scene_obj| {
                    if (scene_obj.getArray("include")) |include_arr| {
                        for (include_arr.items) |include_val| {
                            const include_path = include_val.asString() orelse continue;
                            try loadSceneFile(game, include_path, prefab_cache, include_depth + 1);
                        }
                    }
                    uf.warnLegacyAssets(scene_obj, game.log);
                    // RFC #560 §B2 at the file root: a reference-mode
                    // root may not declare `"children"`.
                    // `uf.rootObject` returns the explicit `"root"`
                    // block when present (root-wrapped legacy v1.x
                    // shape) and the file object itself otherwise
                    // (flat top-level entity, RFC #594), so the
                    // gate fires for either shape.
                    try uf.rejectB2Violation(uf.rootObject(scene_obj), game.log, "reference-mode root");
                    if (uf.fileChildren(scene_obj, game.log)) |entities_arr| {
                        var ref_ctx = RefContext.init(game.allocator, null);
                        defer ref_ctx.deinit();
                        try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
                    }
                },
                .bundle => |bundle| {
                    // RFC #596: consume engine-known directives from
                    // the bundle's file-header `meta:` block BEFORE
                    // spawning entities, so state-gated scripts see
                    // the requested initial state on their first tick.
                    applyFileMetaDirectives(game, bundle.file_meta);
                    if (bundle.entities.len == 0) return;
                    var ref_ctx = RefContext.init(game.allocator, null);
                    defer ref_ctx.deinit();
                    try processEntities(game, .{ .items = bundle.entities }, prefab_cache, &ref_ctx);
                },
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

            // Mirrors `loadSceneFile`'s post-parse dispatch — see
            // the RFC #596 comments there.
            const top = uf.classifyTopLevel(scene_value) orelse return error.InvalidFormat;
            switch (top) {
                .single_root => |scene_obj| {
                    if (scene_obj.getArray("include")) |include_arr| {
                        for (include_arr.items) |include_val| {
                            const include_path = include_val.asString() orelse continue;
                            try loadSceneFile(game, include_path, prefab_cache, 1);
                        }
                    }
                    uf.warnLegacyAssets(scene_obj, game.log);
                    try uf.rejectB2Violation(uf.rootObject(scene_obj), game.log, "reference-mode root");
                    if (uf.fileChildren(scene_obj, game.log)) |entities_arr| {
                        var ref_ctx = RefContext.init(game.allocator, null);
                        defer ref_ctx.deinit();
                        try processEntities(game, entities_arr, prefab_cache, &ref_ctx);
                    }
                },
                .bundle => |bundle| {
                    // Mirrors `loadSceneFile`'s bundle arm — file-
                    // header meta directives (RFC #596) apply equally
                    // to in-memory sources so embedded tests and hot-
                    // reload paths see the same state-machine effect.
                    applyFileMetaDirectives(game, bundle.file_meta);
                    if (bundle.entities.len == 0) return;
                    var ref_ctx = RefContext.init(game.allocator, null);
                    defer ref_ctx.deinit();
                    try processEntities(game, .{ .items = bundle.entities }, prefab_cache, &ref_ctx);
                },
            }
        }
    };
}
