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
//!      declaration order then array order — prefab components
//!      first, then the entry's own `components`/`overrides`,
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
    try walkEntry(ctx, resolver, root_value, .root, 0, null, visitor);
}

fn walkEntry(
    ctx: *WalkContext,
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
    defer if (pushed_prefab) {
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
                try walkEntry(ctx, resolver, child_val, .prefab_child, depth + 1, null, visitor);
            }
        }
    }

    // ── 2. entity entries nested in component fields ────────────
    // Prefab components first, then the entry's own patch — the
    // entry-side patch is walked too because an `overrides` block
    // can introduce nested entities of its own.
    if (prefab_root) |proot| {
        if (proot.getObject("components")) |pc| {
            try walkComponentFields(ctx, resolver, pc, depth, visitor);
        }
    }
    if (uf.entityPatch(obj, NoopLog{})) |patch| {
        try walkComponentFields(ctx, resolver, patch, depth, visitor);
    }

    // ── 3. the entry's own children array ───────────────────────
    if (obj.getArray("children")) |children| {
        for (children.items) |child_val| {
            try walkEntry(ctx, resolver, child_val, .child, depth + 1, null, visitor);
        }
    }
}

/// Walk every entity entry nested inside a component object's array
/// fields. A field is "entity-bearing" when its first array element
/// looks like an entity entry (`isEntityLike`).
fn walkComponentFields(
    ctx: *WalkContext,
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
            if (!isEntityLike(arr.items[0])) continue;
            for (arr.items) |item| {
                if (!isEntityLike(item)) continue;
                try walkEntry(ctx, resolver, item, .component_field, depth + 1, entry.key, visitor);
            }
        }
    }
}

/// Whether a `Value` looks like an entity definition — it has a
/// `prefab` string or a `components` object. Mirrors
/// `component_apply.isEntityLike`; kept here so the walker has no
/// dependency on the component-apply machinery (which is generic
/// over `GameType`).
pub fn isEntityLike(value: Value) bool {
    const obj = value.asObject() orelse return false;
    return obj.getString("prefab") != null or obj.getObject("components") != null;
}

/// A `log`-shaped no-op — `uf.entityPatch` takes a logger to emit
/// deprecation warnings, but a pure structural walk should stay
/// silent (the instantiation pass already warns once per file).
const NoopLog = struct {
    pub fn warn(_: NoopLog, comptime _: []const u8, _: anytype) void {}
    pub fn err(_: NoopLog, comptime _: []const u8, _: anytype) void {}
};
