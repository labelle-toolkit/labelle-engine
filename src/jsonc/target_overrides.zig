//! `@ref`-targeted overrides (#801).
//!
//! A prefab reference's override map may carry `"@<ref>"` keys whose
//! values are ordinary component maps. Each `@` patch applies to every
//! entity inside the reference's instantiated prefab body whose
//! effective `ref` is `<ref>` — component-field nested entities
//! (`Room.workstations`) and prefab children alike, recursively
//! through sub-prefabs. Bare component keys keep their existing
//! meaning (they patch the reference's root entity).
//!
//! Semantics (per the RFC on #801):
//!
//!   - **Whole subtree, every match.** A ref name denotes a role; a
//!     prefab that wants distinct targets gives entities distinct
//!     refs. The search is structural (down-tree) — deliberately
//!     unlike `@ref` *value* resolution, which is lexical (up-scope,
//!     per-instance private, #425).
//!   - **Precedence, outermost author wins.** Prefab defaults < the
//!     nested entry's own overrides < the enclosing reference's `@`
//!     patch < the next-outer reference's `@` patch, and so on out to
//!     the scene. Implemented by folding matched patches onto the
//!     entity's own patch innermost-first, so the outermost merge
//!     lands last.
//!   - **RFC #562 rides along.** A target patch deep-merges via the
//!     same `mergeValues` path as bare overrides; a `"Comp": null`
//!     inside a target patch removes that component from the target.
//!   - **Unmatched `@` is a hard error.** The target is explicit, so
//!     a typo can only be a mistake — `error.InvalidFormat` at load,
//!     after the reference's whole body has been walked.
//!   - **`"@name": null` (removing the target entity) is rejected**
//!     — entity removal would change the shape of patched-back
//!     `[]const u64` id arrays and the cascade-destruction wiring;
//!     out of scope for #801.
//!
//! The context chain lives in the enclosing loader call's merge arena
//! (`TargetCtx` instances and their entry slices are arena-allocated),
//! so hit counters stay valid exactly as long as the body walk that
//! updates them.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const uf = @import("unified_format.zig");

/// One `"@name"` entry: the bare ref name (leading `@` stripped), the
/// component-map patch, and how many entities it has matched so far.
pub const TargetEntry = struct {
    name: []const u8,
    patch: Value,
    hits: usize = 0,
};

/// The targets a single reference entry declared, chained to the
/// enclosing reference's targets. Matching walks the whole chain
/// (inner and outer targets can both hit one entity); accounting is
/// per-context, checked when the declaring reference's body finishes
/// loading.
pub const TargetCtx = struct {
    parent: ?*TargetCtx,
    entries: []TargetEntry,
    /// Prefab name of the declaring reference — for error messages.
    prefab_name: []const u8,
};

/// Split a patch object (an `overrides:` map or the synthesized flat
/// view) into its bare-component half and its `@`-target half. Either
/// half is `null` when empty. Entry slices live in `allocator`
/// (caller's arena); leaf values are shared with `patch`.
pub const PatchParts = struct {
    components: ?Value.Object,
    targets: ?Value.Object,
};

pub fn splitPatch(patch: ?Value.Object, allocator: std.mem.Allocator) error{OutOfMemory}!PatchParts {
    const p = patch orelse return .{ .components = null, .targets = null };
    var target_count: usize = 0;
    for (p.entries) |e| {
        if (uf.isTargetKey(e.key)) target_count += 1;
    }
    // Overwhelmingly common: no `@` keys — the patch IS the component
    // half, no allocation.
    if (target_count == 0) return .{ .components = p, .targets = null };

    const comps = try allocator.alloc(Value.Object.Entry, p.entries.len - target_count);
    const targs = try allocator.alloc(Value.Object.Entry, target_count);
    var ci: usize = 0;
    var ti: usize = 0;
    for (p.entries) |e| {
        if (uf.isTargetKey(e.key)) {
            targs[ti] = e;
            ti += 1;
        } else {
            comps[ci] = e;
            ci += 1;
        }
    }
    return .{
        .components = if (comps.len == 0) null else Value.Object{ .entries = comps },
        .targets = Value.Object{ .entries = targs },
    };
}

/// Build a `TargetCtx` from the `@`-half of a split patch, validating
/// each entry: the value must be a component map (an Object) whose
/// keys are themselves component names — `"@name": null` (entity
/// removal) and nested `@` keys are rejected. Returns `null` when
/// `targets` is null/empty. The context and its entries live in
/// `allocator` (the loader's merge arena).
pub fn buildCtx(
    targets: ?Value.Object,
    prefab_name: []const u8,
    parent: ?*TargetCtx,
    allocator: std.mem.Allocator,
    log: anytype,
) error{ OutOfMemory, InvalidFormat }!?*TargetCtx {
    const t = targets orelse return null;
    if (t.entries.len == 0) return null;

    const entries = try allocator.alloc(TargetEntry, t.entries.len);
    for (t.entries, 0..) |e, i| {
        if (e.value == .null_value) {
            log.err(
                "[target-override] \"{s}\": null on prefab '{s}' — removing a targeted entity is not supported (#801); remove individual components with \"{s}\": {{ \"Comp\": null }} instead.",
                .{ e.key, prefab_name, e.key },
            );
            return error.InvalidFormat;
        }
        const patch_obj = e.value.asObject() orelse {
            log.err(
                "[target-override] the value of \"{s}\" on prefab '{s}' must be a component map (an object of PascalCase component keys) (#801).",
                .{ e.key, prefab_name },
            );
            return error.InvalidFormat;
        };
        for (patch_obj.entries) |pe| {
            if (uf.isTargetKey(pe.key)) {
                log.err(
                    "[target-override] \"{s}\" inside \"{s}\" on prefab '{s}': nested targets are not supported (#801) — target the inner entity's ref directly from the same override map.",
                    .{ pe.key, e.key, prefab_name },
                );
                return error.InvalidFormat;
            }
            // A target patch's keys are component names: PascalCase
            // (RFC #596) or pack-namespaced (`industry__Workstation`,
            // #440 — these start lowercase, so PascalCase alone is
            // the wrong test). A bare data key like `"capacity"` —
            // or a namespaced-looking one with a non-Pascal suffix
            // like `"capacity__oops"` — would silently no-op through
            // `applyComponent`, the exact silence #801 kills; reject
            // loudly (codex P2 ×2 on #802).
            if (!uf.isComponentKeyShape(pe.key)) {
                log.err(
                    "[target-override] \"{s}\" inside \"{s}\" on prefab '{s}' is not a component name (PascalCase or pack-namespaced) — did you mean \"{s}\": {{ \"SomeComponent\": {{ \"{s}\": ... }} }}? (#801)",
                    .{ pe.key, e.key, prefab_name, e.key, pe.key },
                );
                return error.InvalidFormat;
            }
        }
        entries[i] = .{ .name = e.key[1..], .patch = e.value };
    }
    const ctx = try allocator.create(TargetCtx);
    ctx.* = .{ .parent = parent, .entries = entries, .prefab_name = prefab_name };
    return ctx;
}

/// Result of folding matched target patches into an entity's own
/// patch. `matched` is true when at least one target hit — the caller
/// widens `null`-removal semantics to the merged patch in that case
/// (a `null` arriving through a target patch removes the component
/// even on an inline nested entity).
pub const FoldResult = struct {
    patch: ?Value.Object,
    matched: bool,
    /// The matched target patches, in application (inner→outer)
    /// order. Diagnostics need them: an inner patch may ADD a
    /// component that an outer patch legitimately removes, which the
    /// merged map alone cannot distinguish from a removal that never
    /// matched anything (codex on #806).
    matched_patches: []const Value = &.{},
};

/// Fold every target patch in the chain whose name equals `ref_name`
/// onto `own_patch`, innermost context first — so the outermost
/// author's patch merges last and wins conflicting keys (RFC #562
/// deep-merge per step). Increments each matched entry's hit count.
/// Returns the (possibly unchanged) patch.
pub fn foldMatches(
    ctx: ?*TargetCtx,
    ref_name: ?[]const u8,
    own_patch: ?Value.Object,
    arena: std.mem.Allocator,
) error{OutOfMemory}!FoldResult {
    const name = ref_name orelse return .{ .patch = own_patch, .matched = false };
    var matched = false;
    var current: ?Value.Object = own_patch;
    var patches: std.ArrayListUnmanaged(Value) = .empty;
    var c = ctx;
    while (c) |chain| : (c = chain.parent) {
        for (chain.entries) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            entry.hits += 1;
            matched = true;
            try patches.append(arena, entry.patch);
            const base: Value = .{ .object = current orelse Value.Object{ .entries = &.{} } };
            const merged = try uf.mergeValues(base, entry.patch, arena);
            current = merged.asObject().?;
        }
    }
    return .{ .patch = current, .matched = matched, .matched_patches = patches.items };
}

/// Warn once per (prefab, key): a `@` key on a prefab ROOT is
/// skipped, not applied — target keys only mean something on a
/// *reference* (#801). Shared by every loader path that consumes
/// prefab-root components (entity_walker, nested_spawn,
/// prefab_spawn), because a prefab referenced only from a component
/// array or runtime spawn never passes through the top-level apply
/// pass (CodeRabbit on #802). Visible because a silent drop is the
/// failure mode this feature exists to kill.
pub fn warnPrefabRootTarget(log: anytype, prefab_name: []const u8, key: []const u8) void {
    var buf: [256]u8 = undefined;
    const dedup = std.fmt.bufPrint(&buf, "prefab-root-target:{s}:{s}", .{ prefab_name, key }) catch return;
    uf.warnOnceKey(log, dedup, "[target-override] prefab '{s}' declares \"{s}\" on its ROOT — `@` targets belong on a reference's overrides, not a prefab root; skipped (#801).", .{ prefab_name, key });
}

/// Warn once when a `null` removal names a component that neither the
/// resolved prefab nor the entity's own pre-fold patch carries with a
/// value — the removal is a NO-OP, which for a typo'd key
/// (`industry__Storag: null`) reads exactly like success (#803,
/// codex on #806). `own_pre_fold` is the entity's own patch BEFORE
/// `@` folds, so a legitimate removal of a component the entity
/// declared itself stays silent.
pub fn warnNoopRemoval(
    log: anytype,
    key: []const u8,
    prefab_components: ?Value.Object,
    own_pre_fold: ?Value.Object,
    fold_contributions: []const Value,
) void {
    // Only component-shaped keys participate — the widened unknown-
    // component policy deliberately keeps data-shaped lowercase keys
    // silent, and a `null` value must not change that classification
    // (codex on #806).
    if (!uf.isComponentKeyShape(key)) return;
    if (prefab_components) |pc| {
        for (pc.entries) |pe| {
            if (std.mem.eql(u8, pe.key, key) and pe.value != .null_value) return;
        }
    }
    if (own_pre_fold) |own| {
        for (own.entries) |oe| {
            if (std.mem.eql(u8, oe.key, key) and oe.value != .null_value) return;
        }
    }
    // An INNER matched target patch may have added the component the
    // outer (higher-precedence) patch is removing — that removal
    // matched something real (codex on #806).
    for (fold_contributions) |patch| {
        if (patch.asObject()) |po| {
            for (po.entries) |fe| {
                if (std.mem.eql(u8, fe.key, key) and fe.value != .null_value) return;
            }
        }
    }
    var buf: [256]u8 = undefined;
    const dedup = std.fmt.bufPrint(&buf, "noop-removal:{s}", .{key}) catch return;
    uf.warnOnceKey(log, dedup, "[SceneLoader] removal \"{s}\": null matches nothing — neither the prefab nor the entity carries that component, so the removal is a NO-OP. Check the spelling (#803).", .{key});
}

/// After the declaring reference's body has fully loaded: every
/// target must have matched at least one entity. An unmatched `@` is
/// a typo or a prefab that renamed/removed the ref — fail loudly
/// (that silence is the entire point of #801).
pub fn checkAllMatched(ctx: *const TargetCtx, log: anytype) error{InvalidFormat}!void {
    var failed = false;
    for (ctx.entries) |entry| {
        if (entry.hits != 0) continue;
        log.err(
            "[target-override] \"@{s}\" on prefab '{s}' matched no entity — no `ref: \"{s}\"` anywhere in the prefab's body. Check the ref names inside the prefab (#801).",
            .{ entry.name, ctx.prefab_name, entry.name },
        );
        failed = true;
    }
    if (failed) return error.InvalidFormat;
}
