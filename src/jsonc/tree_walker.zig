//! Shared entity-tree walker (RFC #560, ticket #569).
//!
//! The unified scene/prefab format grows entities in **two**
//! structural places:
//!
//!   1. the `children` array of an entity, and
//!   2. prefab references embedded inside entity-bearing component
//!      fields — the `Room.movement_nodes` / `Workstation.storages`
//!      pattern, where a component field is an array of entity
//!      entries.
//!
//! Every consumer that walks the tree (entity instantiation,
//! save/load prefab tagging, `postLoad` hook firing, asset
//! inference, gizmo registration) must cross *both* paths. A walker
//! that crosses one but not the other is exactly the bug shape of
//! engine #467 / #470 / flying-platform-labelle #286 — so N
//! independent traversals re-introduce that bug N times. This module
//! is the single traversal entry point so there is exactly one
//! `children`-and-component-field recursion in the engine.
//!
//! ## Walk order (normative)
//!
//! For each entity entry the walker yields the entry itself
//! **first** (pre-order), then descends in this fixed order:
//!
//!   1. prefab-defined children (`prefab.root.children`),
//!   2. entity entries nested inside component fields, in component
//!      declaration order then array order — walked over the
//!      **effective** component set (the prefab components with the
//!      reference entry's `overrides` deep-merged in and `null`
//!      removals applied, RFC #562), so the traversal matches the
//!      tree the loader actually instantiates,
//!   3. the entry's own `children` array.
//!
//! This order is the contract the hook-order spec (#561) builds on:
//! a parent's `postLoad` sees its prefab subtree, then its nested
//! component entities, then its scene-declared children.
//!
//! ## Cycle detection
//!
//! A prefab-reference cycle (`A -> B -> A`) is a load-time error.
//! The walker tracks the chain of prefab names currently being
//! expanded; re-entering a name already on the stack is
//! `error.PrefabCycle`, and the full chain (e.g. `A -> B -> A`) is
//! written to the caller-supplied diagnostic buffer so the error
//! message can name every link, not just "cycle detected".
//!
//! The walker is allocation-light: it owns a single growable stack
//! of prefab names for cycle detection and nothing else. It does not
//! parse, does not touch the ECS, and does not resolve `@ref`s —
//! callers layer those concerns on top of the yielded entries.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const uf = @import("unified_format.zig");

/// Per-walk scratch allocations — the merged effective-component
/// trees built while reasoning about `overrides` (RFC #562). Owned by
/// the walk; freed when the walk finishes. Kept separate from
/// `WalkContext` (which lives on a caller's stack and is read for
/// `cycle_chain` after the walk returns) so a single arena reset
/// frees every merge without touching the diagnostic buffers.
const MergeArena = std.heap.ArenaAllocator;

/// Error set for a tree walk. `PrefabCycle` carries no payload —
/// the offending chain is reported through `WalkContext.cycle_chain`
/// so the caller can format a message that names every link.
pub const WalkError = error{
    /// A prefab reference re-entered a prefab already being
    /// expanded on the current branch. See `cycle_chain`.
    PrefabCycle,
    /// The walk nested deeper than `max_depth` — a runaway tree or
    /// a `children`/component-field structure with no natural base.
    DepthExceeded,
    OutOfMemory,
};

/// How a particular entity entry was reached. Consumers that treat
/// the two structural birth-places differently (save/load tags only
/// prefab-tree descendants as `PrefabChild`; gizmo registration may
/// skip component-field entities) branch on this.
pub const Origin = enum {
    /// The walk's starting entry.
    root,
    /// Reached through an entity's `children` array.
    child,
    /// Reached through `prefab.root.children` of a referenced prefab.
    prefab_child,
    /// Reached through an entity entry nested inside a component
    /// field (the `Room.movement_nodes` pattern).
    component_field,
};

/// One visit handed to the caller's `visit` callback.
pub fn Node(comptime VisitError: type) type {
    _ = VisitError;
    return struct {
        /// The entity entry's JSONC object — its `components` /
        /// `overrides` / `prefab` / `children` keys.
        obj: Value.Object,
        /// The raw `Value` the object came from (handy for callers
        /// that re-dispatch into existing `Value`-keyed helpers).
        value: Value,
        /// How this entry was reached.
        origin: Origin,
        /// Nesting depth — `0` for the root entry.
        depth: usize,
        /// When `origin == .component_field`, the name of the
        /// component whose field carried this entry (e.g.
        /// `"Room"`); `null` otherwise. Lets a consumer attribute a
        /// nested entity to its owning component.
        component_name: ?[]const u8,
        /// The resolved prefab object when this entry referenced a
        /// `prefab` that was found, else `null`. Already unwrapped
        /// past the `root` block.
        prefab_root: ?Value.Object,
    };
}

/// Per-walk mutable state: the cycle-detection stack and the
/// diagnostic chain buffer. One `WalkContext` per top-level walk;
/// callers `init` it, run the walk, then read `cycle_chain` if the
/// walk returned `error.PrefabCycle`.
pub const WalkContext = struct {
    /// Prefab names currently being expanded, innermost last. A
    /// reference to a name already here is a cycle.
    stack: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Filled with the offending chain when a cycle is hit — the
    /// stack at the point of detection plus the repeated name.
    /// Borrowed slices into the walked tree / prefab registry; valid
    /// as long as those outlive the context.
    cycle_chain: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,
    /// Hard recursion cap — a malformed tree (or a cycle the prefab
    /// resolver fails to surface) can't run away.
    max_depth: usize = 64,

    pub fn init(allocator: std.mem.Allocator) WalkContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WalkContext) void {
        self.stack.deinit(self.allocator);
        self.cycle_chain.deinit(self.allocator);
    }

    /// Render the recorded cycle chain as `A -> B -> A`. The
    /// returned slice is owned by `out_alloc`. Empty when no cycle
    /// was recorded.
    pub fn formatCycleChain(self: *const WalkContext, out_alloc: std.mem.Allocator) ![]const u8 {
        if (self.cycle_chain.items.len == 0) return out_alloc.dupe(u8, "");
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(out_alloc);
        for (self.cycle_chain.items, 0..) |name, i| {
            if (i != 0) try buf.appendSlice(out_alloc, " -> ");
            try buf.appendSlice(out_alloc, name);
        }
        return buf.toOwnedSlice(out_alloc);
    }
};

/// A prefab resolver: maps a prefab name to its parsed `Value`, or
/// `null` when the name is unknown. `PrefabCache.get` satisfies this
/// directly; tests pass a closure over a static table.
pub const Resolver = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, name: []const u8) ?Value,

    pub fn get(self: Resolver, name: []const u8) ?Value {
        return self.getFn(self.ctx, name);
    }
};

/// Walk the entity tree rooted at `root_value`, invoking `visitor`
/// once per entity entry in the normative pre-order. `visitor` must
/// expose `pub fn visit(self, node) VisitError!void` where `node` is
/// `Node(VisitError)`.
///
/// `resolver` resolves `prefab` references so the walk can descend
/// into prefab subtrees; pass a resolver that always returns `null`
/// to walk only the inline structure (no prefab expansion).
///
/// Returns `error.PrefabCycle` (with `ctx.cycle_chain` populated) on
/// a referenced-prefab cycle, or any error the visitor raises.
pub fn walk(
    ctx: *WalkContext,
    resolver: Resolver,
    root_value: Value,
    visitor: anytype,
) (WalkError || @TypeOf(visitor).VisitError)!void {
    var merge_arena = MergeArena.init(ctx.allocator);
    defer merge_arena.deinit();
    try walkEntry(ctx, &merge_arena, resolver, root_value, .root, 0, null, visitor);
}

fn walkEntry(
    ctx: *WalkContext,
    merge_arena: *MergeArena,
    resolver: Resolver,
    entity_value: Value,
    origin: Origin,
    depth: usize,
    component_name: ?[]const u8,
    visitor: anytype,
) (WalkError || @TypeOf(visitor).VisitError)!void {
    const VisitError = @TypeOf(visitor).VisitError;
    if (depth > ctx.max_depth) return error.DepthExceeded;

    const obj = entity_value.asObject() orelse return;

    // Resolve a `prefab` reference, if any. A reference to a prefab
    // already on the expansion stack is a cycle — record the full
    // chain and bail before recursing.
    var prefab_root: ?Value.Object = null;
    var pushed_prefab: bool = false;
    if (obj.getString("prefab")) |prefab_name| {
        for (ctx.stack.items) |on_stack| {
            if (std.mem.eql(u8, on_stack, prefab_name)) {
                ctx.cycle_chain.clearRetainingCapacity();
                try ctx.cycle_chain.appendSlice(ctx.allocator, ctx.stack.items);
                try ctx.cycle_chain.append(ctx.allocator, prefab_name);
                return error.PrefabCycle;
            }
        }
        if (resolver.get(prefab_name)) |prefab_val| {
            if (prefab_val.asObject()) |pobj| {
                prefab_root = uf.rootObject(pobj);
                try ctx.stack.append(ctx.allocator, prefab_name);
                pushed_prefab = true;
            }
        }
    }
    // The expansion stack only guards against *reference-chain*
    // cycles (A's body references B's body references A's body).
    // Steps 1 and 2 walk content that belongs to this prefab's body,
    // so the stack must include this prefab while they recurse. Step
    // 3 walks the entry's own scene-declared `children`, which are a
    // SEPARATE entity tree the scene attached — a child there that
    // references this same prefab is a new finite expansion, not a
    // recursive one. So pop the stack between step 2 and step 3 to
    // avoid a false `error.PrefabCycle` on a legitimate scene entry
    // like `{ "prefab": "A", "children": [{ "prefab": "A" }] }`.
    // `errdefer` covers an early return from steps 1 or 2; the
    // happy-path pop below clears `pushed_prefab` so it does not
    // double-pop.
    errdefer if (pushed_prefab) {
        _ = ctx.stack.pop();
    };

    // Pre-order: yield this entry before descending.
    const node: Node(VisitError) = .{
        .obj = obj,
        .value = entity_value,
        .origin = origin,
        .depth = depth,
        .component_name = component_name,
        .prefab_root = prefab_root,
    };
    try visitor.visit(node);

    // ── 1. prefab-defined children ──────────────────────────────
    if (prefab_root) |proot| {
        if (proot.getArray("children")) |children| {
            for (children.items) |child_val| {
                try walkEntry(ctx, merge_arena, resolver, child_val, .prefab_child, depth + 1, null, visitor);
            }
        }
    }

    // ── 2. entity entries nested in component fields ────────────
    // The walker must reason about the **effective** component tree
    // — the post-#562-merge result the loader actually instantiates,
    // not the raw prefab components. A reference entry's `overrides`
    // can replace an entity-bearing field with a non-cyclic value,
    // or a `null` override can remove a whole component; in either
    // case the entity-bearing fields the prefab declared no longer
    // exist, so walking the raw prefab components would chase a
    // cycle through a field the merged tree has dropped.
    //
    // `effectiveComponents` mirrors `loadEntityInternal`: it deep-
    // merges each override onto the prefab's same-named component
    // (RFC #562, `uf.mergedOverride`), drops `null`-removed
    // components, and carries through override-only components.
    {
        // RFC #596: both the prefab root and the entity entry may
        // expose their components as flat PascalCase keys (no
        // `"components"` / `"overrides"` wrapper). Synthesize the
        // views into `merge_arena` so the cycle walk sees the same
        // effective component tree the loader will instantiate.
        const prefab_components: ?Value.Object =
            if (prefab_root) |proot| try uf.prefabComponents(proot, merge_arena.allocator()) else null;
        const patch = try uf.entityPatch(obj, merge_arena.allocator(), NoopLog{});
        if (try effectiveComponents(merge_arena, prefab_components, patch)) |eff| {
            try walkComponentFields(ctx, merge_arena, resolver, eff, depth, visitor);
        }
    }

    // The prefab's body (steps 1 and 2) is fully expanded — pop
    // before walking scene-declared children so a child that
    // references the same prefab is not mistaken for a cycle.
    if (pushed_prefab) {
        _ = ctx.stack.pop();
        pushed_prefab = false;
    }

    // ── 3. the entry's own children array ───────────────────────
    if (obj.getArray("children")) |children| {
        for (children.items) |child_val| {
            try walkEntry(ctx, merge_arena, resolver, child_val, .child, depth + 1, null, visitor);
        }
    }
}

/// Build the **effective** component object for an entity entry:
/// the prefab's components with the reference entry's `overrides`
/// applied (RFC #562 deep-merge / `null` removal). This is the same
/// component set `SceneLoader.loadEntityInternal` instantiates, so
/// the walker's nested-entity traversal sees exactly the fields the
/// runtime will spawn — no false `PrefabCycle` on a field an
/// override replaced or removed.
///
/// Returns `null` only when neither side carries components. The
/// merged tree lives in `merge_arena`; leaf values are shared with
/// the inputs (same contract as `uf.mergeValues`).
fn effectiveComponents(
    merge_arena: *MergeArena,
    prefab_components: ?Value.Object,
    patch: ?Value.Object,
) error{OutOfMemory}!?Value.Object {
    // Inline entry (no prefab) — its `components` ARE the effective
    // set; nothing to merge.
    const pc = prefab_components orelse return patch;
    // Reference entry with no `overrides` — the prefab components
    // are the effective set unchanged.
    const ov = patch orelse return pc;

    const a = merge_arena.allocator();
    var entries: std.ArrayListUnmanaged(Value.Object.Entry) = .empty;

    // Start from the prefab components, dropping any the override
    // removes via a JSONC `null` (component-level removal, #562).
    for (pc.entries) |pe| {
        const removed = blk: {
            for (ov.entries) |oe| {
                if (std.mem.eql(u8, oe.key, pe.key))
                    break :blk oe.value == .null_value;
            }
            break :blk false;
        };
        if (removed) continue;
        // Deep-merge the override onto this prefab component when
        // the override names it; otherwise keep the prefab value.
        var value = pe.value;
        for (ov.entries) |oe| {
            if (std.mem.eql(u8, oe.key, pe.key) and oe.value != .null_value) {
                value = try uf.mergeValues(pe.value, oe.value, a);
                break;
            }
        }
        try entries.append(a, .{ .key = pe.key, .value = value });
    }

    // Add override-only components (present in `overrides` but not
    // the prefab), skipping `null` removals of nonexistent keys.
    for (ov.entries) |oe| {
        if (oe.value == .null_value) continue;
        const in_prefab = blk: {
            for (pc.entries) |pe| {
                if (std.mem.eql(u8, pe.key, oe.key)) break :blk true;
            }
            break :blk false;
        };
        if (!in_prefab) try entries.append(a, .{ .key = oe.key, .value = oe.value });
    }

    return Value.Object{ .entries = try entries.toOwnedSlice(a) };
}

/// Walk every entity entry nested inside a component object's array
/// fields. A field is "entity-bearing" when ANY array element looks
/// like an entity entry (`isEntityLike`) — consistent with the
/// loader's `spawnAndLinkNestedEntities`, which scans every item.
/// Checking only `[0]` would miss a cycle reached through an
/// entity-like item that is not first in the array.
fn walkComponentFields(
    ctx: *WalkContext,
    merge_arena: *MergeArena,
    resolver: Resolver,
    components: Value.Object,
    depth: usize,
    visitor: anytype,
) (WalkError || @TypeOf(visitor).VisitError)!void {
    for (components.entries) |entry| {
        const comp_obj = entry.value.asObject() orelse continue;
        for (comp_obj.entries) |field| {
            const arr = field.value.asArray() orelse continue;
            if (arr.items.len == 0) continue;
            for (arr.items) |item| {
                if (!isEntityLike(item)) continue;
                try walkEntry(ctx, merge_arena, resolver, item, .component_field, depth + 1, entry.key, visitor);
            }
        }
    }
}

/// Whether a `Value` looks like an entity definition — it has a
/// `prefab` string, a `components` object (wrapped form), or any
/// PascalCase key (flat form, RFC #596 Axis 2). Mirrors
/// `component_apply.isEntityLike`; kept here so the walker has no
/// dependency on the component-apply machinery (which is generic
/// over `GameType`).
pub fn isEntityLike(value: Value) bool {
    const obj = value.asObject() orelse return false;
    if (obj.getString("prefab") != null) return true;
    if (obj.getObject("components") != null) return true;
    for (obj.entries) |e| {
        if (uf.isPascalCase(e.key)) return true;
    }
    return false;
}

/// A `log`-shaped no-op — `uf.entityPatch` takes a logger to emit
/// deprecation warnings, but a pure structural walk should stay
/// silent (the instantiation pass already warns once per file).
const NoopLog = struct {
    pub fn warn(_: NoopLog, comptime _: []const u8, _: anytype) void {}
    pub fn err(_: NoopLog, comptime _: []const u8, _: anytype) void {}
};
