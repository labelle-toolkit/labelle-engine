//! Bounded live-instance prefab refresh (#691).
//!
//! After `editor_reload_prefab` swaps a prefab's registry entry
//! (contract v1.3, `PrefabCache.replaceFromSource`), this module
//! re-applies the prefab's **`.transient`-policy components** onto the
//! instances already spawned from it — the same component set the
//! save/load contract already resets from prefab data on every
//! `loadGameState` (Phase 1 respawns; `.transient` never rides the
//! save file). Everything else keeps the live-refresh guarantees the
//! full destroy+respawn design was rejected over: entity identity,
//! runtime `.saveable` state, and every reference other entities hold
//! stay untouched.
//!
//! ## Scope contract (what refreshes, what deliberately does not)
//!
//!   * Only registry components whose `getSavePolicy(T) == .transient`.
//!     `Position` / `Sprite` / `Shape` are structural/renderer-owned
//!     (special-cased by name in `component_apply.zig` before the
//!     registry loop) and are never touched — visual-definition edits
//!     to those still need a respawn or scene reload.
//!   * Declared-key diffing, not entity diffing: a transient component
//!     the GAME attached at runtime (FP's condenser gate toggling
//!     `SpriteAnimation`, `Selection`, …) is invisible to the diff —
//!     only keys that appear in the OLD prefab JSON and vanished from
//!     the NEW one are removed. This intentionally diverges from pure
//!     load semantics (load destroys the entity, so runtime attachments
//!     die with it; refresh preserves the live entity, so game-owned
//!     attachments keep their meaning).
//!   * Children are matched through their spawn-time
//!     `PrefabChild.local_path` resolved against BOTH trees in
//!     lockstep, gated on equal `children` array lengths at every
//!     level: a structural edit (add/remove a child) skips the child
//!     refresh rather than risk re-applying entry N's components onto
//!     the entity spawned from old entry N±1. Same-length reorders
//!     cannot be detected — reordering children mid-Play refreshes the
//!     wrong sibling until a respawn/scene reload converges it.
//!   * Reference-mode children (`{ "prefab": "x", "overrides": … }`)
//!     refresh when the prefab that DECLARES them is pushed (their
//!     effective set is `mergedOverride` over the referenced prefab's
//!     current components). Pushing the REFERENCED prefab does not
//!     walk containing instances — those children also carry their own
//!     `PrefabInstance` tag, but the root pass skips `PrefabChild`
//!     carriers precisely so a base-prefab push can never clobber
//!     override-merged values. Future spawns pick the new base up
//!     immediately; live ref-children converge on respawn.
//!   * Entity-ref fields (`[]const u64` arrays and any field named in
//!     the component's `entity_ref_fields`) are preserved from the old
//!     component: the spawn path patches those AFTER apply
//!     (`patchEntityIdField`), so re-deserializing from JSON would
//!     zero live links to nested entities.
//!   * `onReady`/`postLoad` fire per re-applied key — load-consistent
//!     (Phase 1 respawn fires them on every `loadGameState` too).
//!
//! Visibility: the refresh only writes ECS components. The renderer
//! picks the change up on the next TICKED frame (`renderer.sync` lives
//! in `tick`'s always-run block) — under `editor_pause` that is the
//! next `editor_step`/resume, exactly like `editor_load_animation_def`.
//!
//! Wired into `game.refresh_prefab_fn` by the scene loader's public
//! entry points, right next to `spawn_prefab_fn` — the fn pointer (not
//! a Game mixin) because the refresh needs the BRIDGE's `Components`
//! registry: hosts may parameterize the bridge with a registry that is
//! not `Game.ComponentRegistry`.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const core = @import("labelle-core");
const Position = core.Position;

const prefab_cache_mod = @import("../prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const uf = @import("../unified_format.zig");
const component_apply_mod = @import("../component_apply.zig");
const on_ready_mod = @import("../on_ready.zig");

/// Follow at most this many `{ "prefab": … }` alias hops when
/// resolving a node to its authored (component/children-bearing)
/// form. Reference chains deeper than this are authoring errors the
/// spawn path's cycle gate already rejects; the refresh just bails.
const MAX_REF_HOPS = 4;

pub fn PrefabRefresh(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;
    const ApplyHelpers = component_apply_mod.ComponentApply(GameType, Components);
    const OnReadyHelpers = on_ready_mod.OnReady(GameType, Components);

    return struct {
        /// One declared component: registry key + effective JSON value
        /// (override-merged for reference-mode nodes).
        const Declared = struct { key: []const u8, value: Value };

        /// A `null` slice means the declaration set could not be
        /// computed (arena OOM, unresolvable reference) — callers
        /// treat it as "unknown": nothing is applied from an unknown
        /// new set, nothing is removed against an unknown old set.
        const DeclaredSet = ?[]const Declared;

        /// Wired into `game.refresh_prefab_fn`. `key` is the registry
        /// key the new source was installed under (its effective
        /// name); `old_opaque` is a `*const jsonc.Value` of the
        /// retired generation (opaque so `game.zig` stays jsonc-free —
        /// same rationale as `prefab_cache_ptr`), or null when the
        /// push INSERTED a brand-new prefab (nothing can be live).
        pub fn refreshPrefabInstancesImpl(
            game: *GameType,
            key: []const u8,
            old_opaque: ?*const anyopaque,
        ) void {
            const old_ptr: *const Value = @ptrCast(@alignCast(old_opaque orelse return));
            const cache_ptr = game.prefab_cache_ptr orelse return;
            const cache: *PrefabCache = @ptrCast(@alignCast(cache_ptr));
            const new_val = cache.getInstalled(key) orelse return;
            const new_obj = new_val.asObject() orelse return;
            const old_obj = old_ptr.*.asObject() orelse return;
            const new_root = uf.rootObject(new_obj);
            const old_root = uf.rootObject(old_obj);

            // Everything the diff synthesizes (flat-component views,
            // merged overrides, matched-entity lists) lives here; leaf
            // values are shared with the cache's trees (never freed),
            // so nothing a component keeps can dangle.
            var arena = std.heap.ArenaAllocator.init(game.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const new_comps = rootDeclared(new_root, a, game.log);
            const old_comps = rootDeclared(old_root, a, game.log);

            // Collect matches FIRST, mutate after: add/removeComponent
            // moves entities between archetypes on real backends,
            // which invalidates live view iterators.
            var roots: std.ArrayList(Entity) = .empty;
            var children: std.ArrayList(Entity) = .empty;
            {
                var view = game.ecs_backend.view(.{GameType.PrefabInstanceComp}, .{});
                defer view.deinit();
                while (view.next()) |entity| {
                    if (!instanceMatches(game, cache, entity, new_val)) continue;
                    // Reference-mode children carry BOTH tags (walker
                    // tags the reference, the outer root's tag walk
                    // marks descent) — their effective set is the
                    // override-merged one owned by the CONTAINING
                    // declaration, so the root pass must not clobber
                    // it with the base prefab's values.
                    if (game.ecs_backend.getComponent(entity, GameType.PrefabChildComp) != null) continue;
                    roots.append(a, entity) catch return;
                }
            }
            {
                var view = game.ecs_backend.view(.{GameType.PrefabChildComp}, .{});
                defer view.deinit();
                while (view.next()) |entity| {
                    const pc = game.ecs_backend.getComponent(entity, GameType.PrefabChildComp) orelse continue;
                    if (!instanceMatches(game, cache, pc.root, new_val)) continue;
                    children.append(a, entity) catch return;
                }
            }

            for (roots.items) |entity| {
                refreshEntity(game, entity, old_comps, new_comps);
            }
            for (children.items) |entity| {
                const pc = game.ecs_backend.getComponent(entity, GameType.PrefabChildComp) orelse continue;
                const pair = resolveLocalPathPair(old_root, new_root, pc.local_path, cache) orelse continue;
                const child_old = nodeDeclared(pair.old, cache, a, game.log);
                const child_new = nodeDeclared(pair.new, cache, a, game.log);
                refreshEntity(game, entity, child_old, child_new);
            }
        }

        // ── Instance matching ──────────────────────────────────────

        /// Does `entity`'s `PrefabInstance.path` resolve — through the
        /// installed registry only, no disk fallback side effects — to
        /// the tree that was just installed? Tree identity is entries
        /// pointer identity: `replaceFromSource` installs exactly one
        /// parsed tree per generation.
        fn instanceMatches(game: *GameType, cache: *PrefabCache, entity: Entity, new_val: Value) bool {
            const inst = game.ecs_backend.getComponent(entity, GameType.PrefabInstanceComp) orelse return false;
            const resolved = cache.getInstalled(inst.path) orelse return false;
            return sameTree(resolved, new_val);
        }

        fn sameTree(x: Value, y: Value) bool {
            const xo = x.asObject() orelse return false;
            const yo = y.asObject() orelse return false;
            return xo.entries.ptr == yo.entries.ptr;
        }

        // ── Declared-component views ───────────────────────────────

        /// Declared set of a prefab ROOT (always author-mode —
        /// `replaceFromSource`'s §B2 gate rejects reference roots
        /// carrying children, and pure alias roots have no components
        /// to declare). `null` values are skipped: an inline `null`
        /// carries no removal meaning (RFC #562 scopes removal to
        /// reference `overrides`), so it is neither applied nor
        /// treated as declared.
        fn rootDeclared(root: Value.Object, a: std.mem.Allocator, log: anytype) DeclaredSet {
            const comps = (uf.prefabComponents(root, a, log) catch return null) orelse
                return &.{};
            var list: std.ArrayList(Declared) = .empty;
            for (comps.entries) |entry| {
                if (entry.value == .null_value) continue;
                list.append(a, .{ .key = entry.key, .value = entry.value }) catch return null;
            }
            return list.toOwnedSlice(a) catch null;
        }

        /// Declared set of a child NODE — inline entities use their
        /// own `components` view; reference-mode entities merge their
        /// `overrides` onto the referenced prefab's current components
        /// (`null` override = removal, RFC #562: the key counts as NOT
        /// declared, so a live component under it is removed like any
        /// other dropped key).
        fn nodeDeclared(node: Value.Object, cache: *PrefabCache, a: std.mem.Allocator, log: anytype) DeclaredSet {
            const is_reference = node.getString("prefab") != null;
            const patch = uf.entityPatch(node, a, log) catch return null;

            if (!is_reference) {
                const comps = patch orelse return &.{};
                var list: std.ArrayList(Declared) = .empty;
                for (comps.entries) |entry| {
                    if (entry.value == .null_value) continue;
                    list.append(a, .{ .key = entry.key, .value = entry.value }) catch return null;
                }
                return list.toOwnedSlice(a) catch null;
            }

            const resolved = resolveNode(node, cache) orelse return null;
            const base = uf.prefabComponents(resolved, a, log) catch return null;

            var handled = std.StringHashMap(void).init(a);
            var list: std.ArrayList(Declared) = .empty;
            if (patch) |p| {
                for (p.entries) |entry| {
                    handled.put(entry.key, {}) catch return null;
                    if (entry.value == .null_value) continue; // removal
                    const merged = uf.mergedOverride(base, entry.key, entry.value, a) catch return null;
                    list.append(a, .{ .key = entry.key, .value = merged }) catch return null;
                }
            }
            if (base) |b| {
                for (b.entries) |entry| {
                    if (handled.contains(entry.key)) continue;
                    if (entry.value == .null_value) continue;
                    list.append(a, .{ .key = entry.key, .value = entry.value }) catch return null;
                }
            }
            return list.toOwnedSlice(a) catch null;
        }

        /// Follow `{ "prefab": … }` alias hops through the INSTALLED
        /// registry until an author-mode node (bounded, no disk I/O).
        fn resolveNode(node: Value.Object, cache: *PrefabCache) ?Value.Object {
            var cur = node;
            var hops: u8 = 0;
            while (cur.getString("prefab")) |pname| {
                hops += 1;
                if (hops > MAX_REF_HOPS) return null;
                const v = cache.getInstalled(pname) orelse return null;
                const o = v.asObject() orelse return null;
                cur = uf.rootObject(o);
            }
            return cur;
        }

        // ── local_path resolution (lockstep, length-gated) ─────────

        const NodePair = struct { old: Value.Object, new: Value.Object };

        /// Walk a spawn-time `children[i].children[j]…` path through
        /// BOTH trees at once (format produced by
        /// `tagAsPrefabInstance` and consumed by the save mixin's
        /// `findChildByLocalPath`). Reference-mode nodes descend
        /// through the referenced prefab's current children (§B2
        /// guarantees a reference node authors none of its own). Any
        /// level where the two arrays disagree in length is a
        /// structural edit — return null and leave that child alone.
        fn resolveLocalPathPair(
            old_root: Value.Object,
            new_root: Value.Object,
            local_path: []const u8,
            cache: *PrefabCache,
        ) ?NodePair {
            if (local_path.len == 0) return null;
            var cur_old = old_root;
            var cur_new = new_root;
            var rest = local_path;
            while (rest.len > 0) {
                if (rest[0] == '.') rest = rest[1..];
                const prefix = "children[";
                if (!std.mem.startsWith(u8, rest, prefix)) return null;
                rest = rest[prefix.len..];
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[0..close], 10) catch return null;
                rest = rest[close + 1 ..];

                const old_res = resolveNode(cur_old, cache) orelse return null;
                const new_res = resolveNode(cur_new, cache) orelse return null;
                const old_children = old_res.getArray("children") orelse return null;
                const new_children = new_res.getArray("children") orelse return null;
                if (old_children.items.len != new_children.items.len) return null;
                if (idx >= new_children.items.len) return null;
                cur_old = old_children.items[idx].asObject() orelse return null;
                cur_new = new_children.items[idx].asObject() orelse return null;
            }
            return .{ .old = cur_old, .new = cur_new };
        }

        // ── Per-entity diff + re-apply ─────────────────────────────

        /// `Position`/`Sprite`/`Shape` are name-special-cased in
        /// `applyComponent` BEFORE its registry loop — they must never
        /// enter the transient path even if a host registers a
        /// same-named registry type.
        fn isReservedName(name: []const u8) bool {
            return std.mem.eql(u8, name, "Position") or
                std.mem.eql(u8, name, "Sprite") or
                std.mem.eql(u8, name, "Shape");
        }

        fn containsKey(set: []const Declared, key: []const u8) bool {
            for (set) |kv| {
                if (std.mem.eql(u8, kv.key, key)) return true;
            }
            return false;
        }

        /// Re-apply every transient key declared in NEW; remove every
        /// transient key declared in OLD that NEW dropped. Unknown
        /// (`null`) sets fail safe: no applies from an unknown new, no
        /// removals against an unknown old.
        fn refreshEntity(game: *GameType, entity: Entity, old_set: DeclaredSet, new_set: DeclaredSet) void {
            if (new_set) |ns| {
                for (ns) |kv| {
                    if (isReservedName(kv.key)) continue;
                    applyTransient(game, entity, kv.key, kv.value);
                }
            }
            if (old_set) |os| {
                const ns = new_set orelse return;
                for (os) |kv| {
                    if (isReservedName(kv.key)) continue;
                    if (containsKey(ns, kv.key)) continue;
                    removeTransient(game, entity, kv.key);
                }
            }
        }

        /// Comptime-dispatch a single named component; only
        /// `.transient`-policy registry types pass. The old
        /// component's entity-ref fields survive the re-deserialize
        /// (the spawn path patches those AFTER apply — see
        /// `patchEntityIdField` — so the JSON never carries live
        /// ids). `onReady`/`postLoad` fire exactly like a Phase 1
        /// respawn would.
        fn applyTransient(game: *GameType, entity: Entity, name: []const u8, value: Value) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (comptime isTransient(T)) {
                        const prev: ?T = if (game.ecs_backend.getComponent(entity, T)) |p| p.* else null;
                        ApplyHelpers.applyComponent(game, entity, name, value, Position{});
                        if (prev) |old_comp| preserveEntityRefs(T, game, entity, old_comp);
                        OnReadyHelpers.fireOnReadyByName(game, entity, name);
                    }
                    return;
                }
            }
        }

        fn removeTransient(game: *GameType, entity: Entity, name: []const u8) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (comptime isTransient(T)) {
                        if (game.ecs_backend.getComponent(entity, T) != null) {
                            game.removeComponent(entity, T);
                        }
                    }
                    return;
                }
            }
        }

        fn isTransient(comptime T: type) bool {
            if (@typeInfo(T) != .@"struct") return false;
            return (core.getSavePolicy(T) orelse .saveable) == .transient;
        }

        /// Copy entity-ref fields (declared `entity_ref_fields` plus
        /// every `[]const u64` field — the shape `patchEntityIdField`
        /// writes) from the pre-refresh component into the freshly
        /// applied one.
        fn preserveEntityRefs(comptime T: type, game: *GameType, entity: Entity, prev: T) void {
            const cur = game.ecs_backend.getComponent(entity, T) orelse return;
            const ref_fields = comptime core.getEntityRefFields(T);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const is_ref = comptime blk: {
                    if (field.type == []const u64) break :blk true;
                    for (ref_fields) |rf| {
                        if (std.mem.eql(u8, rf, field.name)) break :blk true;
                    }
                    break :blk false;
                };
                if (is_ref) @field(cur, field.name) = @field(prev, field.name);
            }
        }
    };
}
