//! Nested-entity spawn for component array fields —
//! `spawnAndLinkNestedEntities`.
//!
//! Extracted from `scene_loader.zig` (slice of the <1000-line split).
//! Spawns entity-like objects nested inside a component's array fields,
//! collects their entity IDs, and patches them back into the
//! component's `[]const u64` fields. Mutually recursive with the parent
//! loader's `loadEntityInternal`. Behavior is identical to the inlined
//! version — only the source location moved.

const std = @import("std");
const builtin = @import("builtin");
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

pub fn NestedSpawn(comptime GameType: type, comptime Components: type, comptime Self: type) type {
    const Entity = GameType.EntityType;
    const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
    const RefContext = RefResolver.RefContext;
    const ApplyHelpers = component_apply_mod.ComponentApply(GameType, Components);
    const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);

    return struct {
        /// Spawn entity-like objects nested inside a component's
        /// fields, collect their entity IDs, and patch them back
        /// into the component's `[]const u64` fields.
        pub fn spawnAndLinkNestedEntities(
            game: *GameType,
            parent_entity: Entity,
            comp_name: []const u8,
            comp_value: Value,
            parent_world_pos: Position,
            prefab_cache: *PrefabCache,
            depth: usize,
            ref_ctx: ?*RefContext,
        ) Self.LoadEntityError!void {
            const obj = comp_value.asObject() orelse return;

            // Arena for deep-merged override component values
            // (RFC #562) — mirrors the block in `loadEntityInternal`.
            var merge_arena = std.heap.ArenaAllocator.init(game.allocator);
            defer merge_arena.deinit();

            for (obj.entries) |entry| {
                const arr = entry.value.asArray() orelse continue;

                // RFC #560 §B2: pre-scan for component-nested
                // entries that smuggle `{prefab + children}` through
                // a component array — the visit-time gate in
                // `loadEntityInternal` doesn't fire on this walk
                // path, so without this check a violation here loads
                // silently. Propagate `error.InvalidFormat` so the
                // top-level load returns the failure (matches the
                // file-root and child-entry gates).
                for (arr.items) |item| {
                    if (!ApplyHelpers.isEntityLike(item)) continue;
                    const item_obj = item.asObject() orelse continue;
                    try uf.rejectB2Violation(item_obj, game.log, "component-nested entity");
                }

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
                                        // RFC #560 §B2: re-validate
                                        // the resolved prefab's own
                                        // root for the
                                        // `{prefab + children}` shape
                                        // (mirrors the matching block
                                        // in `loadEntityInternal`).
                                        // Propagate the error so the
                                        // top-level load fails — the
                                        // child entity already exists,
                                        // so an `errdefer` on the
                                        // caller path would normally
                                        // clean it up, but here we
                                        // rely on the scene load's
                                        // overall failure to surface
                                        // the diagnostic.
                                        try uf.rejectB2Violation(proot, game.log, "resolved prefab root");
                                        // RFC #596: flat prefab root has
                                        // its components as PascalCase
                                        // keys; the synthesized view
                                        // lives in `merge_arena` (above)
                                        // so it shares the apply / merge
                                        // pipeline's lifetime.
                                        child_prefab_comps = try uf.prefabComponents(proot, merge_arena.allocator(), game.log);
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
                            // Flat shape (RFC #596) synthesizes the
                            // view from PascalCase keys; the entries
                            // slice lives in `merge_arena` (declared
                            // at the top of `spawnAndLinkNestedEntities`).
                            const child_scene_comps = try uf.entityPatch(child_obj, merge_arena.allocator(), game.log);

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
                                    try spawnAndLinkNestedEntities(game, child, e.key, effective, child_pos, prefab_cache, depth + 1, nested_ref_ctx);
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
                                        try spawnAndLinkNestedEntities(game, child, e.key, e.value, child_pos, prefab_cache, depth + 1, nested_ref_ctx);
                                    }
                                }
                            }

                            // Process children (prefab children +
                            // inline children) (#415).
                            // Save world pos before setParent to
                            // avoid double-offset (#417).
                            if (child_prefab_children) |children| {
                                for (children.items) |child_val| {
                                    const grandchild = Self.loadEntityInternal(game, child_val, prefab_cache, depth + 1, child_pos, nested_ref_ctx) catch |err| {
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
                                    const grandchild = Self.loadEntityInternal(game, child_val, prefab_cache, depth + 1, child_pos, nested_ref_ctx) catch |err| {
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
