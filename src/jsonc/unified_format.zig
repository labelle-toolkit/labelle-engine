//! Unified scene/prefab format accessors (RFC #560, ticket #561).
//!
//! The unified format wraps a file's entity content in an explicit
//! `"root"` block, lists file-level entities under `"children"`
//! (not `"entities"`), and names a prefab reference's patch data
//! `"overrides"` (not `"components"`). Legacy spellings are still
//! accepted during the migration window; each logs a one-time
//! deprecation warning so the #572 migrator has a checklist.
//!
//! These accessors are the single place that bridges the two
//! shapes — the loader calls them instead of reading raw keys, so
//! `"root"`-wrapped and legacy files walk the exact same code path.
//!
//! See RFC-UNIFY-SCENES-AND-PREFABS.md.

const std = @import("std");
const builtin = @import("builtin");
const jsonc = @import("jsonc");
const Value = jsonc.Value;

// Persistent allocator for the process-lifetime `warned` set. On
// `wasm32-emscripten` `std.heap.page_allocator` resolves to
// `WasmAllocator` and bypasses emscripten's `_emscripten_resize_heap`
// / `updateMemoryViews()`, reintroducing the stale-`HEAPU32`
// memory-growth hazard this codebase deliberately avoids. Use
// `c_allocator` on emscripten (libc malloc routes through emscripten's
// resize path), keep `page_allocator` on desktop. Mirrors the
// `persistent_allocator` / `intern_backing_allocator` convention in
// `prefab_cache.zig` and `deserializer.zig`.
const warned_allocator: std.mem.Allocator = if (builtin.target.os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;

// One-time deprecation-warning dedup, keyed by the comptime message
// literal. A legacy prefab spawned N times — or a scene with N
// legacy references — then warns once, not N times. Never freed
// (process-lifetime set); keys are string literals so there is
// nothing to dupe.
//
// Unguarded on purpose. Gemini-review on #573 asked why this isn't
// behind a `std.Thread.Mutex` — the answer is two-fold:
//
//  1. Scene loading runs on the main thread on every supported
//     platform (desktop, mobile, wasm). `warnOnce` has no other
//     callers, so there is no concurrent reader/writer to race
//     against today.
//  2. The dedup set's *capacity* is bounded by the number of
//     distinct comptime message literals in this file (currently
//     three). `StringHashMap` only rehashes when crossing a load
//     factor on `put`, and three entries never reach the initial
//     allocation's threshold — so the table's backing buffer is
//     written once and then only read. Even a hypothetical second
//     thread emitting one of those same three messages would observe
//     a stable buffer and at worst produce one duplicate log line.
//
// If a future change adds a parallel asset pipeline, or adds many
// more distinct deprecation messages (re-introducing the rehash
// case), add a `std.Thread.Mutex` here before flipping that switch.
var warned: ?std.StringHashMap(void) = null;

fn warnOnce(log: anytype, comptime msg: []const u8) void {
    if (warned == null) {
        warned = std.StringHashMap(void).init(warned_allocator);
    }
    const gop = warned.?.getOrPut(msg) catch return;
    if (gop.found_existing) return;
    log.warn(msg, .{});
}

/// Unwrap the explicit `"root"` block. Unified files put the root
/// entity's `components`/`children`/`ref` inside `"root"`; legacy
/// files keep them at the file's top level. Returns the object that
/// carries the root entity content either way.
pub fn rootObject(file_obj: Value.Object) Value.Object {
    return file_obj.getObject("root") orelse file_obj;
}

/// The file-level entity list for a scene file. Unified:
/// `root.children`. Legacy: a top-level `"entities"` array (warned).
/// A legacy file already using a top-level `"children"` is honored
/// too, so a half-migrated file still loads.
///
/// Partial-migration safety: if `"root"` is present but carries no
/// `"children"` array, we still consult the legacy top-level
/// `"entities"` / `"children"` keys before giving up — otherwise a
/// scene that adds the `"root"` wrapper before moving its entity
/// list silently loads as empty (#573).
pub fn fileChildren(file_obj: Value.Object, log: anytype) ?Value.Array {
    if (file_obj.getObject("root")) |root| {
        if (root.getArray("children")) |children| return children;
        // `root` is present but empty — fall through to legacy keys
        // (warned) so a half-migrated file still loads its entities.
    }
    if (file_obj.getArray("entities")) |entities| {
        warnOnce(log, "[unified-format] legacy \"entities\" key: wrap the entity array in a \"root\" block and rename it to \"children\" (RFC #560)");
        return entities;
    }
    return file_obj.getArray("children");
}

/// The component patch for an entity entry. Inline entries (no
/// `"prefab"`) carry `"components"`. Reference entries (`"prefab"`
/// set) carry `"overrides"`; a legacy `"components"` on a reference
/// is accepted as a synonym and warned. When both are present,
/// `"overrides"` wins.
pub fn entityPatch(entity_obj: Value.Object, log: anytype) ?Value.Object {
    if (entity_obj.getString("prefab") == null) {
        // Inline entity — components are the only patch source.
        return entity_obj.getObject("components");
    }
    // Reference entry — overrides, with a legacy `components` fallback.
    if (entity_obj.getObject("overrides")) |overrides| {
        if (entity_obj.getObject("components") != null) {
            warnOnce(log, "[unified-format] prefab reference has both \"overrides\" and \"components\"; \"overrides\" wins — remove \"components\" (RFC #560)");
        }
        return overrides;
    }
    if (entity_obj.getObject("components")) |legacy| {
        warnOnce(log, "[unified-format] legacy \"components\" on a prefab reference: rename it to \"overrides\" (RFC #560)");
        return legacy;
    }
    return null;
}

/// The registry key for a prefab/scene file: its `"name"` field
/// when present, otherwise the caller-supplied filename basename.
/// Lets a file be referenced by a name that diverges from its
/// path — and is the value collisions are checked against
/// (RFC #560, #561).
pub fn effectiveName(file_obj: Value.Object, basename: []const u8) []const u8 {
    return file_obj.getString("name") orelse basename;
}

/// Warn once if a scene file still declares the dropped `"assets"`
/// field. Under the unified format assets are inferred from sprite
/// references (RFC #563); the field is ignored.
pub fn warnLegacyAssets(file_obj: Value.Object, log: anytype) void {
    if (file_obj.get("assets") != null) {
        warnOnce(log, "[unified-format] legacy \"assets\" key is ignored — assets are inferred from sprite references (RFC #560, #563)");
    }
}

/// RFC §B2 gate: a reference-mode entry (one that carries a
/// `"prefab"` field) is *instantiating*, not *authoring*. Appending a
/// `"children"` array at the call site would silently re-author the
/// referenced recipe — exactly the surprise §B2 forbids. Inline mode
/// (`"components"` + `"children"`) is the place that legitimately
/// nests; if a use site needs to grow a prefab's content, the growth
/// becomes a wrapper prefab in its own file (RFC §Examples #3).
///
/// Returns `error.InvalidFormat` if `entry_obj` has both `"prefab"`
/// and `"children"` set. The error message names RFC §B2 explicitly
/// so a reader landing on a load-time failure can find the spec.
///
/// `site_label` is the human-readable site name — currently
/// `"reference-mode root"` (file-root violation) or
/// `"child entry"` (nested violation). Callers pre-classify so the
/// log line tells the author *where* in the file to look.
///
/// The assembler rejects this shape pre-build at `codegen/scan.zig`
/// (labelle-assembler#182); this gate is the engine-side complement,
/// catching content that bypassed the assembler (embedded sources in
/// tests, hand-edited save files, third-party tools).
pub fn rejectB2Violation(entry_obj: Value.Object, log: anytype, site_label: []const u8) error{InvalidFormat}!void {
    if (entry_obj.getString("prefab") == null) return;
    if (entry_obj.getArray("children") == null) return;
    log.err(
        "[unified-format] RFC §B2 violation at {s}: a prefab reference cannot also declare \"children\" — references instantiate, they do not author. Move the extra entities into a wrapper prefab (RFC #560 §B2).",
        .{site_label},
    );
    return error.InvalidFormat;
}

// ── Override merge (RFC #562) ───────────────────────────────────

/// Deep-merge `patch` onto `base`, returning a new `Value`.
///
/// Objects merge recursively — keys only in `base` are kept, keys
/// only in `patch` are added, and a key in both recurses when both
/// sides are objects. Arrays and scalars in `patch` replace
/// outright (no element-wise list merge). A JSONC `null` in `patch`
/// is carried through as a value — component-level removal is
/// handled by the caller before this is reached.
///
/// The returned tree's entry arrays come from `arena`; leaf values
/// (strings, numbers) are shared with `base`/`patch`, so the result
/// must not outlive either input. Allocation failure is propagated
/// as `error.OutOfMemory` — silently degrading to whole-component
/// replacement would drop the prefab's inherited fields and violate
/// the accepted deep-merge semantics (RFC #562).
pub fn mergeValues(base: Value, patch: Value, arena: std.mem.Allocator) error{OutOfMemory}!Value {
    const base_obj = base.asObject() orelse return patch;
    const patch_obj = patch.asObject() orelse return patch;

    var entries: std.ArrayListUnmanaged(Value.Object.Entry) = .empty;
    // Pre-size for the worst case (every patch key is new) so the
    // hot loop below appends without reallocating mid-merge.
    try entries.ensureTotalCapacity(arena, base_obj.entries.len + patch_obj.entries.len);
    entries.appendSliceAssumeCapacity(base_obj.entries);

    for (patch_obj.entries) |pe| {
        for (entries.items) |*existing| {
            if (std.mem.eql(u8, existing.key, pe.key)) {
                const both_objects =
                    existing.value.asObject() != null and pe.value.asObject() != null;
                existing.value = if (both_objects)
                    try mergeValues(existing.value, pe.value, arena)
                else
                    pe.value;
                break;
            }
        } else {
            entries.appendAssumeCapacity(pe);
        }
    }
    return .{ .object = .{ .entries = entries.items } };
}

/// The effective value to apply for an overridden component: the
/// override deep-merged onto the prefab's same-named component when
/// the prefab declares one, otherwise the override value as-is.
/// Callers handle a `null` override (component removal) first.
///
/// Propagates `error.OutOfMemory` from the underlying merge — the
/// caller must not fall back to whole-component replacement.
pub fn mergedOverride(
    prefab_components: ?Value.Object,
    key: []const u8,
    override_value: Value,
    arena: std.mem.Allocator,
) error{OutOfMemory}!Value {
    const pc = prefab_components orelse return override_value;
    const base = pc.get(key) orelse return override_value;
    return mergeValues(base, override_value, arena);
}
