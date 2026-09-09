//! Load-only JSON accessors — the shape-guard layer for the reader.
//!
//! Extracted verbatim from `save_load/load.zig`; behaviour is identical.
//! These are the safe, tag-checked accessors the load path uses to read a
//! parsed save file: every one returns `null` (or a benign default) on a
//! tag mismatch rather than panicking via a `.object` / `.integer` tag-cast,
//! so a malformed / hand-edited save produces a logged warning and a skipped
//! entity instead of a debug-assertion panic or release-mode memory
//! corruption.
//!
//! Split out of the reader because they're pure (`std.json`-only, no `Game`,
//! no `Entity`, no registry): keeping them here gives the rehydration
//! sequence in `load.zig` a single concern (the Phase 1a/1b/1c → Phase 2
//! walk) and gives these guards a standalone home. `load.zig` re-aliases
//! them at mixin scope so its call sites read exactly as before. Behaviour
//! (including the malformed-save hardening these enforce) stays covered by
//! `test/save_load_mixin_test.zig` and `test/save_load_two_phase_test.zig`,
//! which exercise the full load path.

const std = @import("std");

/// Read a boolean field out of a serialised Parent object, defaulting to
/// `false` for missing / non-bool values. Keeps the save and load sides of
/// the built-in Parent pathway symmetric and the call sites free of the
/// `switch (v) { .bool => ... }` boilerplate.
pub fn parentFlag(parent_obj: std.json.ObjectMap, field: []const u8) bool {
    const v = parent_obj.get(field) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// Read the `components` sub-object of a save entry. Returns `null` when the
/// entry isn't an object or its `components` field is missing / not an
/// object — so a malformed entry is skipped rather than tag-cast-panicking.
pub fn getComponentsObject(entry: std.json.Value) ?std.json.ObjectMap {
    if (entry != .object) return null;
    const comps_val = entry.object.get("components") orelse return null;
    return switch (comps_val) {
        .object => |o| o,
        else => null,
    };
}

/// Read an object-typed field, or `null` on missing / wrong-tag.
pub fn getObjectField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// Read a string-typed field, or `null` on missing / wrong-tag.
pub fn getStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read a non-negative integer field as `u64` (for entity IDs). Clamps
/// negative and out-of-range values to `null` so the caller's
/// `orelse continue` pattern gracefully drops malformed entries.
pub fn getU64Field(obj: std.json.ObjectMap, name: []const u8) ?u64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        // `std.math.cast` returns null when the i64 doesn't fit u64
        // (negatives, and — vacuously — any out-of-range value), so a
        // negative / malformed entity id is dropped without an `@intCast`
        // trap. Idiomatic replacement for the manual `i >= 0` guard.
        .integer => |i| std.math.cast(u64, i),
        else => null,
    };
}

/// Read the top-level `id` of a save entry as `u64`. Missing or non-integer
/// `id` fields return `null` so the caller can skip the entry instead of
/// panicking.
pub fn getSavedId(entry: std.json.Value) ?u64 {
    if (entry != .object) return null;
    return getU64Field(entry.object, "id");
}

/// Read a numeric field as `f32`, accepting both `.float` and `.integer`
/// JSON tags; returns 0 for missing or non-numeric values. Used for the
/// Position shim in Phase 1a.
pub fn getNumberField(obj: std.json.ObjectMap, name: []const u8) f32 {
    const v = obj.get(name) orelse return 0;
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}
