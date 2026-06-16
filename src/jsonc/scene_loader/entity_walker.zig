//! Entity-tree walker — `loadEntityInternal` + `loadChildEntity`.
//!
//! Extracted from `scene_loader.zig` (slice of the <1000-line split).
//! The unified per-entity loader: resolves the prefab, deep-merges
//! `overrides`, applies components (with `@ref` deferral), spawns
//! nested entities, fires `onReady`, tags prefab instances, and
//! recurses into children. Mutually recursive with the parent loader's
//! `spawnAndLinkNestedEntities`. Behavior is identical to the inlined
//! version — only the source location moved.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const core = @import("labelle-core");
const Position = core.Position;

const prefab_cache_mod = @import("../prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const uf = @import("../unified_format.zig");
const ref_resolver_mod = @import("../ref_resolver.zig");
const component_apply_mod = @import("../component_apply.zig");
const on_ready_mod = @import("../on_ready.zig");

pub fn EntityWalker(comptime GameType: type, comptime Components: type, comptime Self: type) type {
    const Entity = GameType.EntityType;
    const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
    const RefContext = RefResolver.RefContext;
    const ApplyHelpers = component_apply_mod.ComponentApply(GameType, Components);
    const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);

    return struct {
        /// Unified entity loader — handles top-level and child
        /// entities, with optional ref context for `@ref`
        /// cross-reference support.
        ///
        /// When `ref_ctx` is non-null, registers `ref` names and
        /// applies components with `@ref` strings replaced by `0`
        /// (patched in pass 2). When `ref_ctx` is null, follows the
        /// original single-pass path.
        pub fn loadEntityInternal(game: *GameType, entity_val: Value, prefab_cache: *PrefabCache, depth: usize, parent_offset: Position, ref_ctx: ?*RefContext) Self.LoadEntityError!Entity {
            if (depth > Self.MAX_DEPTH) return error.IncludeDepthExceeded;
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

            // Merge / synthesized-view arena. `merge_arena` holds:
            //   - the synthesized flat-form components view for both
            //     the entity (RFC #596 Axis 2, `entityPatch`) and the
            //     resolved prefab root (`prefabComponents`) when
            //     neither carries an `overrides:` / `components:`
            //     wrapper;
            //   - the deep-merged override component values (RFC #562).
            // Leaf values are shared with `entity_obj` / the prefab,
            // so the arena's lifetime only needs to span this
            // function's body.
            var merge_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer merge_arena.deinit();

            // `null`-as-removal is scoped to reference entries'
            // `overrides` (RFC #562) — an inline entity's
            // `components` have no removal semantics. Hoisted above
            // `entityPatch` so the `is_reference` branch is
            // already known when we classify the patch shape.
            const is_reference = entity_obj.getString("prefab") != null;

            // Resolve prefab. After RFC #596, a prefab's components
            // may sit either inside an explicit `"components"`
            // wrapper or as flat PascalCase keys at the root —
            // `uf.prefabComponents` handles both, allocating the
            // synthesized view into `merge_arena` in the flat case.
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
                        // RFC #560 §B2: the resolved prefab's own
                        // root may not itself be `{prefab + children}`.
                        // The file-root gate only fires for scenes
                        // loaded via `loadSceneFile`/`loadSceneSource`
                        // — `addEmbeddedPrefab` and third-party
                        // prefab sources land in the cache unchecked,
                        // so re-validate here at every resolution.
                        try uf.rejectB2Violation(proot, game.log, "resolved prefab root");
                        prefab_components = try uf.prefabComponents(proot, merge_arena.allocator(), game.log);
                        prefab_children = proot.getArray("children");
                    }
                }
            }

            // For a reference entry this is the `overrides` patch;
            // for an inline entry, its own `components`. The flat
            // form (RFC #596) synthesizes the view from the entity's
            // PascalCase keys; the wrapped form returns the existing
            // Object verbatim.
            const scene_components = try uf.entityPatch(entity_obj, merge_arena.allocator(), game.log);

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
            // The merge tree lives in `merge_arena` (declared above);
            // its leaf strings are shared with the prefab/override
            // inputs, so `@ref` names collected from a merged
            // component stay valid into the pass-2 patch even after
            // the arena frees.

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
                    try Self.spawnAndLinkNestedEntities(game, entity, entry.key, effective, entity_pos, prefab_cache, depth, ref_ctx);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        try Self.spawnAndLinkNestedEntities(game, entity, entry.key, entry.value, entity_pos, prefab_cache, depth, ref_ctx);
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
        pub fn loadChildEntity(
            game: *GameType,
            parent_entity: Entity,
            child_val: Value,
            prefab_cache: *PrefabCache,
            depth: usize,
            parent_pos: Position,
            ref_ctx: ?*RefContext,
        ) Self.LoadEntityError!void {
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
    };
}
