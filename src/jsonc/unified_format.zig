//! Unified scene/prefab format accessors (RFC #560 + RFC #594 + RFC #596).
//!
//! The unified format lists file-level entities under `"children"`
//! (not `"entities"`) and names a prefab reference's patch data
//! `"overrides"` (not `"components"`). The file's entity content
//! lives either inside an explicit `"root"` wrapper (v1.0 — v1.x)
//! or directly at the file top level (RFC #594, recommended from
//! v1.47 onward, only shape in v2.0). RFC #596 extends this further
//! with three new axes:
//!
//!   - **Wrapper-flat components.** PascalCase keys at the entity
//!     scope are components directly — no `overrides:` /
//!     `components:` wrapper. Lowercase keys (`prefab`, `children`,
//!     `meta`, `ref`) stay structural. Dual-accept during v1.x.
//!   - **File-as-array bundles.** The file's top-level JSON value
//!     can be an Array of sibling entities — no implicit root. An
//!     optional header element (only-`meta` object at index 0)
//!     carries file-level metadata.
//!   - **`meta:` field.** Free-form authoring-only data at entity
//!     and file-header scope; stripped at load, never reaches
//!     runtime.
//!   - **Unknown PascalCase → warn-once.** Forward-compat with
//!     cross-repo plugin authoring; typos still surface visibly.
//!
//! Pre-#560 legacy spellings — a top-level `"entities"` array, a
//! `"components"` wrapper on a prefab reference, and a top-level
//! `"assets"` array — are NO LONGER accepted as of engine v2.0
//! (#592). The loader rejects each with an actionable
//! `error.InvalidFormat` that points at the `labelle migrate
//! unified` CLI migrator (which rewrites legacy files to the
//! unified/flat form).
//!
//! These accessors are the single place that bridges the shapes —
//! the loader calls them instead of reading raw keys, so flat,
//! `"root"`-wrapped, and bundle files all walk the exact same code
//! path. Per RFC #594 "Loader changes", every current shape is
//! first-class and warning-free; the pre-#560 legacy aliases were
//! removed in the v2.0 major bump (#592).
//!
//! See RFC-UNIFY-SCENES-AND-PREFABS.md, RFC-FLATTEN-ROOT.md, and
//! RFC-FLATTEN-WRAPPERS-AND-BUNDLES.md.

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

// One-time warning dedup, keyed by the comptime message literal.
// The pre-#560 legacy deprecation warnings were removed in v2.0
// (#592); the remaining callers are RFC #596 forward-compat
// diagnostics — the defense-in-depth "mixed wrapper + flat
// PascalCase shapes" warnings on inline entities, prefab references,
// and prefab roots. A scene that trips one of these N times then
// warns once, not N times. Never freed (process-lifetime set); keys
// are string literals so there is nothing to dupe.
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

// Separate dedup set for runtime-formatted warnings (unknown
// component names, file-specific diagnostics). Keys are duped into
// `warned_allocator` because the format strings are runtime-built
// and would otherwise dangle. Same threading rationale as `warned`
// above — load is single-threaded today.
var warned_runtime: ?std.StringHashMap(void) = null;

/// Warn-once for a runtime-formatted message. The first call with a
/// given `key` logs `msg`; later calls with an equal `key` are
/// suppressed. `key` is duped into the process-lifetime allocator on
/// first sight so the caller's buffer can free safely.
fn warnOnceKey(log: anytype, key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (warned_runtime == null) {
        warned_runtime = std.StringHashMap(void).init(warned_allocator);
    }
    const gop = warned_runtime.?.getOrPut(key) catch return;
    if (gop.found_existing) return;
    // Dupe the key so the caller can free its scratch buffer. The
    // hashmap stores the duped pointer; nothing frees it (this is a
    // process-lifetime dedup set).
    const owned = warned_allocator.dupe(u8, key) catch {
        _ = warned_runtime.?.remove(key);
        return;
    };
    gop.key_ptr.* = owned;
    log.warn(fmt, args);
}

/// True if `name` looks PascalCase: starts with an ASCII uppercase
/// letter. RFC #596's case convention — PascalCase keys at the
/// entity scope are components, lowercase keys are structural
/// (`prefab`, `children`, `meta`, `ref`). Empty or non-ASCII-start
/// names return false (treated as structural so we don't accidentally
/// classify e.g. an explicit-`null` key as a component).
pub fn isPascalCase(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] >= 'A' and name[0] <= 'Z';
}

/// Warn once that an unknown PascalCase component appeared on an
/// entity (RFC #596 Axis 4). The component is treated as a no-op
/// override / declaration so authoring against a not-yet-loaded
/// plugin still works — but the warning catches typos like
/// `Posiiton` visibly. Audit promotes this to a finding.
///
/// Deduped by component name across the whole process; a typo in
/// 50 scene entries warns once, not 50 times.
pub fn warnUnknownComponent(log: anytype, name: []const u8) void {
    // 256B scratch covers any realistic component name. If a name
    // overruns we drop the warning rather than allocate — a name
    // long enough to overrun is already obviously broken.
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "unknown-component:{s}", .{name}) catch return;
    warnOnceKey(log, key, "[unified-format] unknown component '{s}' on entity — treated as no-op (RFC #596). If this is a typo, fix it; if it's a forward-compat reference to a not-yet-loaded plugin, ignore this warning.", .{name});
}

/// Unwrap the explicit `"root"` block. The unified format ships two
/// shapes during the v1.x deprecation window (RFC #594):
///
///  - **Root-wrapped (v1.0 — v1.x):** the root entity's
///    `components`/`children`/`prefab`/`overrides` sit inside a
///    top-level `"root"` object. This is the original shape from
///    RFC #560.
///  - **Flat (v1.47+ recommended, v2.0 only):** the top-level keys
///    of the file ARE the root entity. Metadata keys (`name`,
///    future `version`) coexist at the same level because the key
///    sets are closed and disjoint (RFC #594 §"Key sets are closed
///    and disjoint").
///
/// Returns the object that carries the root entity content either
/// way: the explicit `"root"` block when present, the file object
/// itself otherwise.
pub fn rootObject(file_obj: Value.Object) Value.Object {
    return file_obj.getObject("root") orelse file_obj;
}

/// Reject the pre-#560 legacy file-level aliases. As of engine v2.0
/// (#592) the loader accepts only the unified/flat form, so a scene
/// file that still carries either:
///
///  - a top-level `"entities"` array (the pre-#560 wrapper; the
///    unified form lists file-level entities under `"children"`, or
///    directly as a top-level bundle Array), or
///  - a top-level `"assets"` array (assets are inferred from sprite
///    references — RFC #563),
///
/// is rejected with `error.InvalidFormat` and an actionable message
/// pointing at the `labelle migrate unified` CLI migrator. Callers
/// invoke this before `fileChildren` so a legacy file fails loudly
/// instead of silently loading as empty.
pub fn rejectLegacyAliases(file_obj: Value.Object, log: anytype) error{InvalidFormat}!void {
    if (file_obj.get("entities") != null) {
        log.err(
            "[unified-format] legacy \"entities\" key is no longer accepted (removed in engine v2.0, #592): list file-level entities under \"children\", or as a top-level bundle Array. Run `labelle migrate unified` to convert this file.",
            .{},
        );
        return error.InvalidFormat;
    }
    if (file_obj.get("assets") != null) {
        log.err(
            "[unified-format] legacy \"assets\" key is no longer accepted (removed in engine v2.0, #592): assets are inferred from sprite references (RFC #563). Run `labelle migrate unified` to convert this file.",
            .{},
        );
        return error.InvalidFormat;
    }
}

/// The file-level entity list for a scene file. Two shapes ride the
/// same accessor:
///
///  - **Root-wrapped (v1.0 — v1.x):** `root.children`.
///  - **Flat (RFC #594):** top-level `"children"` array sitting
///    alongside `"name"` / future metadata.
///
/// The pre-#560 legacy top-level `"entities"` array is no longer
/// honored (removed in v2.0, #592) — `rejectLegacyAliases` fails such
/// a file before this is reached.
pub fn fileChildren(file_obj: Value.Object) ?Value.Array {
    if (file_obj.getObject("root")) |root| {
        if (root.getArray("children")) |children| return children;
        // `root` is present but empty — fall through to a top-level
        // `"children"` so a half-migrated file still loads its
        // entities.
    }
    return file_obj.getArray("children");
}

/// The result of parsing a file's top-level shape.
///
/// RFC #596 Axis 3 introduces the **bundle** shape — the file's
/// top-level JSON value is an Array of sibling entities, no
/// implicit root. The first array element MAY be a "file header"
/// (an object whose only entity-shape key is `meta:`) carrying
/// file-level metadata; the loader treats it as metadata, not an
/// entity.
///
/// Existing single-root files (object top-level) ride the
/// `.single_root` variant unchanged.
pub const TopLevel = union(enum) {
    /// File top-level is a single Object — the existing single-root
    /// shape (RFC #560 / #594). Process via `rootObject` /
    /// `fileChildren` as before.
    single_root: Value.Object,
    /// File top-level is an Array of sibling entities. `entities`
    /// excludes the optional file-header element; `file_meta` holds
    /// the header's `meta` value (or null when no header present).
    bundle: Bundle,

    pub const Bundle = struct {
        entities: []Value,
        file_meta: ?Value,
    };
};

/// Classify the file's top-level value. Object → single-root;
/// Array → bundle (RFC #596 Axis 3). Anything else (string,
/// number, …) is malformed — returns `null` so the caller can
/// surface `error.InvalidFormat` without this helper having to
/// know the loader's error type.
///
/// The bundle header is detected by inspecting the first array
/// element only: if it's an object whose ONLY keys are `meta` (no
/// `prefab`, no `children`, no PascalCase, no `components` /
/// `overrides` legacy wrappers — none of the entity-shape keys),
/// it's the header. Anything else at index 0 is an entity. Empty
/// arrays `[]` are valid zero-entity bundles (no warning).
pub fn classifyTopLevel(file_val: Value) ?TopLevel {
    switch (file_val) {
        .object => |o| return .{ .single_root = o },
        .array => |a| {
            if (a.items.len == 0) {
                return .{ .bundle = .{ .entities = &.{}, .file_meta = null } };
            }
            // Header detection: index 0 is an object whose only
            // recognized key is `meta` (no entity-shape keys).
            if (a.items[0].asObject()) |first_obj| {
                if (isFileHeader(first_obj)) {
                    return .{ .bundle = .{
                        .entities = a.items[1..],
                        .file_meta = first_obj.get("meta"),
                    } };
                }
            }
            return .{ .bundle = .{ .entities = a.items, .file_meta = null } };
        },
        else => return null,
    }
}

/// True if `obj` is a file-level metadata header — an object that
/// contains `meta:` and NO entity-shape keys. Entity-shape keys are
/// `prefab`, `children`, `components`, `overrides` (legacy), or any
/// PascalCase key (RFC #596). A header MAY also be `{}` (empty
/// object), but that's not a useful header and we treat it as an
/// entity (the existing `loadEntityInternal` will reject `{}` as
/// malformed).
fn isFileHeader(obj: Value.Object) bool {
    if (obj.get("meta") == null) return false;
    for (obj.entries) |e| {
        if (std.mem.eql(u8, e.key, "meta")) continue;
        // Any entity-shape key disqualifies — this is an entity
        // that happens to carry a `meta` field, not a file header.
        if (std.mem.eql(u8, e.key, "prefab")) return false;
        if (std.mem.eql(u8, e.key, "children")) return false;
        if (std.mem.eql(u8, e.key, "components")) return false;
        if (std.mem.eql(u8, e.key, "overrides")) return false;
        if (std.mem.eql(u8, e.key, "ref")) return false;
        if (isPascalCase(e.key)) return false;
        // Other lowercase keys (e.g. unknown future structural
        // keys) are tolerated on the header — `meta`-shaped side
        // data.
    }
    return true;
}

/// The component patch for an entity entry. Two shapes ride this
/// accessor (RFC #560 / #594 / #596):
///
///   - **Wrapped:** inline entries carry `"components": { ... }`;
///     reference entries carry `"overrides": { ... }`. As of engine
///     v2.0 (#592) the pre-#560 `"components"` wrapper on a *prefab
///     reference* is rejected with `error.InvalidFormat` (it must be
///     `"overrides"`); an inline entity still uses `"components"`.
///   - **Flat (RFC #596 Axis 2):** PascalCase keys at the entity
///     scope are the components directly — no `overrides:` /
///     `components:` wrapper. Lowercase keys (`prefab`, `children`,
///     `meta`, `ref`) stay structural. Mode (inline vs reference)
///     is determined by whether `prefab` is present, exactly as in
///     the wrapped form.
///   - **Mixed (defense-in-depth):** if both an explicit wrapper
///     AND PascalCase keys at the entity scope exist, the wrapper
///     wins (back-compat) and we warn once. Authoring tools should
///     never produce this; the migrator either lifts the wrapper or
///     leaves it alone, but a hand-edited file could land here.
///
/// `allocator` is used only when synthesizing the flat-form
/// components view (the wrapped paths just return the existing
/// Object verbatim). Callers pass their per-scene arena; the
/// synthesized Object's `entries` slice lives in that arena and
/// must not outlive it. Leaf values are shared with `entity_obj`.
pub fn entityPatch(entity_obj: Value.Object, allocator: std.mem.Allocator, log: anytype) error{ OutOfMemory, InvalidFormat }!?Value.Object {
    const is_reference = entity_obj.getString("prefab") != null;

    if (is_reference) {
        // A prefab reference patches via `"overrides"` (or flat
        // PascalCase keys, RFC #596). The pre-#560 `"components"`
        // wrapper on a reference is no longer accepted (removed in
        // v2.0, #592) — reject it loudly instead of silently
        // ignoring the patch.
        if (entity_obj.get("components") != null) {
            log.err(
                "[unified-format] legacy \"components\" on a prefab reference is no longer accepted (removed in engine v2.0, #592): rename it to \"overrides\", or use flat PascalCase component keys (RFC #596). Run `labelle migrate unified` to convert this file.",
                .{},
            );
            return error.InvalidFormat;
        }
        if (entity_obj.getObject("overrides")) |overrides| {
            if (hasPascalCaseKey(entity_obj)) {
                warnOnce(log, "[unified-format] reference entry has both an \"overrides\" wrapper and flat PascalCase keys — \"overrides\" wins. Drop one shape (RFC #596).");
            }
            return overrides;
        }
    } else {
        if (entity_obj.getObject("components")) |components| {
            if (hasPascalCaseKey(entity_obj)) {
                warnOnce(log, "[unified-format] inline entity has both a \"components\" wrapper and flat PascalCase keys — wrapper wins. Drop one shape (RFC #596).");
            }
            return components;
        }
    }

    // Flat form (RFC #596 Axis 2): synthesize a components view
    // from the PascalCase keys at the entity scope. Lowercase keys
    // are structural and skipped. An entity with no PascalCase keys
    // returns null (no components to apply) — matches the wrapped
    // path's "no `components`/`overrides`" return.
    return try synthesizeFlatComponents(entity_obj, allocator);
}

/// Whether `entity_obj` has at least one PascalCase key at its top
/// level. Used to detect the flat shape without allocating a
/// synthetic Object — and to warn when wrapped + flat are mixed.
fn hasPascalCaseKey(entity_obj: Value.Object) bool {
    for (entity_obj.entries) |e| {
        if (isPascalCase(e.key)) return true;
    }
    return false;
}

/// Build a `Value.Object` whose entries are the entity's PascalCase
/// keys — the components view for the flat shape (RFC #596 Axis 2).
/// `meta` and other lowercase keys are skipped. Returns `null` when
/// there are no PascalCase keys at all (parity with the wrapped
/// path's "no components" return; lets the caller treat an entity
/// with only `prefab` and `meta` as a no-op spawn).
///
/// Entries slice lives in `allocator` (caller's arena). Leaf values
/// are shared with `entity_obj`, so the synthesized Object must not
/// outlive `entity_obj`.
fn synthesizeFlatComponents(entity_obj: Value.Object, allocator: std.mem.Allocator) error{OutOfMemory}!?Value.Object {
    var count: usize = 0;
    for (entity_obj.entries) |e| {
        if (isPascalCase(e.key)) count += 1;
    }
    if (count == 0) return null;

    const entries = try allocator.alloc(Value.Object.Entry, count);
    var i: usize = 0;
    for (entity_obj.entries) |e| {
        if (isPascalCase(e.key)) {
            entries[i] = e;
            i += 1;
        }
    }
    return Value.Object{ .entries = entries };
}

/// The components view of a resolved prefab root. Two shapes:
///
///   - **Wrapped (today):** `prefab_root.components` is the
///     components Object.
///   - **Flat (RFC #596):** PascalCase keys at `prefab_root` ARE the
///     components.
///
/// Returns `null` if neither shape has any components — a prefab
/// with only `children` (or only structural keys) is well-formed
/// per RFC #596; the loader spawns its children with no inherited
/// components. `allocator` is used only to synthesize the flat
/// view; mirrors `entityPatch`'s arena contract.
///
/// If both an explicit `"components"` wrapper AND flat PascalCase
/// keys appear at `prefab_root`, the wrapper wins (back-compat) and
/// we warn once — same dual-shape rule `entityPatch` enforces on
/// inline entries.
pub fn prefabComponents(prefab_root: Value.Object, allocator: std.mem.Allocator, log: anytype) error{OutOfMemory}!?Value.Object {
    if (prefab_root.getObject("components")) |c| {
        if (hasPascalCaseKey(prefab_root)) {
            warnOnce(log, "[unified-format] prefab root has both a \"components\" wrapper and flat PascalCase keys — wrapper wins. Drop one shape (RFC #596).");
        }
        return c;
    }
    return try synthesizeFlatComponents(prefab_root, allocator);
}

/// The registry key for a prefab/scene file: its `"name"` field
/// when present, otherwise the caller-supplied filename basename.
/// Lets a file be referenced by a name that diverges from its
/// path — and is the value collisions are checked against
/// (RFC #560, #561).
pub fn effectiveName(file_obj: Value.Object, basename: []const u8) []const u8 {
    return file_obj.getString("name") orelse basename;
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
