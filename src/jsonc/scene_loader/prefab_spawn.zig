//! Runtime prefab instantiation — `spawnPrefabImpl`.
//!
//! Extracted from `scene_loader.zig` (slice of the <1000-line split).
//! Creates an entity from a named prefab at runtime; wired into
//! `game.spawn_prefab_fn` by the public load entry points. Calls back
//! into the parent loader (`Self`) for cycle gating, nested-entity
//! spawn, and child loading. Behavior is identical to the inlined
//! version — only the source location moved.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const core = @import("labelle-core");
const Position = core.Position;

const prefab_cache_mod = @import("../prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const uf = @import("../unified_format.zig");
const tree_walker = @import("../tree_walker.zig");
const component_apply_mod = @import("../component_apply.zig");
const on_ready_mod = @import("../on_ready.zig");

pub fn PrefabSpawn(comptime GameType: type, comptime Components: type, comptime Self: type) type {
    const Entity = GameType.EntityType;
    const ApplyHelpers = component_apply_mod.ComponentApply(GameType, Components);
    const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);

    return struct {
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

            // RFC #560 §B2: the resolved prefab's own root may not
            // itself be a `{prefab + children}` shape. If the prefab
            // file was authored as a reference-mode root carrying
            // `"children"`, the file-root gates in
            // `loadSceneFile`/`loadSceneSource` would have caught it
            // for scenes, but `addEmbeddedPrefab` (and any third-party
            // prefab source) parses without that gate — so re-check
            // here at every use site rather than rely on the
            // ingestion path. `spawnPrefabImpl` returns `?Entity`, so
            // surface the violation as a logged error + null spawn
            // (the helper already logged the diagnostic).
            uf.rejectB2Violation(prefab_root, game.log, "resolved prefab root") catch return null;

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
                Self.checkEntityTreeCycles(game, ref_entry, prefab_cache, &cycle_ctx) catch |err| {
                    game.log.err("[spawnPrefab] '{s}' not spawned: {s}", .{ name, @errorName(err) });
                    return null;
                };
            }

            // RFC #596: prefab components may sit in the explicit
            // `"components"` wrapper or as flat PascalCase keys at
            // the root. The synthesized view (flat case) lives in a
            // local arena bound to this spawn — its entries slice is
            // walked twice (apply + nested-spawn) but never escapes
            // the function. Leaf values are shared with the cache's
            // prefab tree, so the prefab itself outlives `pc_arena`.
            var pc_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer pc_arena.deinit();
            const prefab_components = (uf.prefabComponents(prefab_root, pc_arena.allocator(), game.log) catch null) orelse return null;

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
            // `spawnAndLinkNestedEntities` now propagates §B2
            // violations; `spawnPrefabImpl` has no error channel, so
            // log and bail (returning the partially-built entity is
            // worse than returning null — the prefab content is
            // malformed and shouldn't appear in the world).
            const entity_pos = game.getPosition(entity);
            for (prefab_components.entries) |entry| {
                Self.spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, 0, null) catch |err| {
                    game.log.err("[spawnPrefab] '{s}' nested-entity load failed: {s}", .{ name, @errorName(err) });
                    return null;
                };
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
                    const child = Self.loadEntityInternal(game, child_val, prefab_cache, 1, entity_pos, null) catch continue;
                    const world_pos = game.getPosition(child);
                    game.setParent(child, entity, .{});
                    game.setWorldPosition(child, world_pos);
                }
            }

            // Tag the root (+ children) as a prefab instance so save/load
            // Phase 1 can reinstantiate it — same step the scene-load path
            // (`loadEntityInternal`) performs via `tagAsPrefabInstance`.
            // Without this, a runtime-`spawnPrefab`'d entity carries no
            // `PrefabInstance`, so on load only its saveable game components
            // come back and its non-saveable prefab visuals (Sprite, etc.)
            // are lost — `spawnPrefab`'s own docstring promises this tagging.
            game.tagAsPrefabInstance(entity, name) catch |err| {
                game.log.err("[spawnPrefab] tagAsPrefabInstance('{s}') failed: {s}", .{ name, @errorName(err) });
            };

            return entity;
        }
    };
}
