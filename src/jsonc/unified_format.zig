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
const jsonc = @import("jsonc");
const Value = jsonc.Value;

// One-time deprecation-warning dedup, keyed by the comptime message
// literal. A legacy prefab spawned N times — or a scene with N
// legacy references — then warns once, not N times. Unguarded on
// purpose: scene loading is single-threaded and the worst case of a
// race is one duplicate warning line. Never freed (process-lifetime
// set); keys are string literals so there is nothing to dupe.
var warned: ?std.StringHashMap(void) = null;

fn warnOnce(log: anytype, comptime msg: []const u8) void {
    if (warned == null) {
        warned = std.StringHashMap(void).init(std.heap.page_allocator);
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
pub fn fileChildren(file_obj: Value.Object, log: anytype) ?Value.Array {
    if (file_obj.getObject("root")) |root| {
        return root.getArray("children");
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
