//! JSONC → Zig-struct deserialization for the scene bridge.
//!
//! Pure value-to-value mapping with no dependency on `GameType`,
//! `Components`, or the wider scene loader. Extracted from the
//! 1,479-line `jsonc_scene_bridge.zig` monolith as Slice 1 of #495.
//! Behavior is unchanged from the in-place version; the only public
//! surface is `deserialize` (recursive entry point) — the helpers
//! are file-local because the recursion uses them directly.
//!
//! Lifetime:
//!  - `[]const u8` strings are interned via the file-scope arena
//!    (`internString`) so identical strings dedupe across spawns
//!    and the cost stays bounded by unique-string count rather
//!    than spawn count. Never freed; survives process lifetime.
//!  - Other slices (`[]const Struct`, etc.) come from the caller's
//!    arena allocator. The scene loader passes the per-world
//!    `nested_entity_arena`, which resets on `resetEcsBackend`.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;

// ── String intern pool ──────────────────────────────────────────────
//
// Component `[]const u8` fields deserialized from a scene or prefab
// need to outlive the parse arena (which is freed after a
// `loadSceneFile`/`loadSceneSource` call returns). We intern them
// into a single arena wrapping `page_allocator` and dedupe via a
// hashmap: identical strings (e.g. "player.png" shared by many
// entities, or a prefab spawned N times) collapse to one allocation.
//
// Bounded by the number of *unique* strings seen over the process
// lifetime, not by the number of deserialize calls — so repeated
// prefab spawns no longer leak page_allocator memory per call.
//
// File-scope on purpose: shared across all bridge instantiations so
// a project with multiple Game types still dedupes. Never freed;
// matches the PrefabCache `page_allocator` convention.
//
// Thread-safety: scene loading is single-threaded today, but the
// asset pipeline (#440 / #461) runs decode work on a worker thread
// and could grow into adjacent paths that touch the deserializer.
// Guard the mutable state with a mutex so the intern pool can't
// race even if we end up with concurrent loads later (gemini review
// on #496). The lock scope is the lazy-init + map lookup + arena
// dupe + map put — all the read/write touchpoints — so a single
// `internString` call is atomic from the caller's perspective.
var intern_arena: ?std.heap.ArenaAllocator = null;
var intern_map: ?std.StringHashMap(void) = null;
var intern_mutex: std.Thread.Mutex = .{};

fn internString(s: []const u8) ?[]const u8 {
    intern_mutex.lock();
    defer intern_mutex.unlock();

    if (intern_arena == null) {
        intern_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        intern_map = std.StringHashMap(void).init(intern_arena.?.allocator());
    }
    if (intern_map.?.getKey(s)) |existing| return existing;
    const owned = intern_arena.?.allocator().dupe(u8, s) catch return null;
    intern_map.?.put(owned, {}) catch return null;
    return owned;
}

/// Deserialize a JSONC `Value` into a Zig type `T`.
/// Returns `null` on type mismatch or malformed payload — the caller
/// (typically `deserializeStruct`) treats `null` as "use default if
/// available, else propagate failure to the parent struct."
pub fn deserialize(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
    const info = @typeInfo(T);

    // Optionals — JSONC `null` → component field stays `null`,
    // anything else unwraps and recurses with the child type.
    // Must run BEFORE the string check so `?[]const u8` fields
    // (e.g. `SpriteByField.Entry.sprite_name`) reach here instead
    // of getting routed into the string branch with a null value
    // and failing.
    //
    // Three distinct `null`s live at this boundary:
    //
    //   * JSONC `null` on an `?U` field — the field should
    //     *successfully* deserialize to `U`'s `null`. Returned as
    //     `@as(T, null)` so Zig coerces it as a non-null outer
    //     Optional whose inner is `?U`'s null.
    //
    //   * Inner deserialize fails on a non-null JSON value (type
    //     mismatch, malformed data) — this has to propagate as a
    //     bare `null` from the function so `deserializeStruct`'s
    //     `orelse` path reads it as "failed, use default / fail
    //     the parent struct."
    //
    //   * Inner deserialize succeeds with a value — wrap it back
    //     into the outer Optional via `@as(T, v)` so the caller
    //     sees "succeeded, value is non-null."
    //
    // The earlier version of this branch naively `return`-ed the
    // inner call's `?U` directly, which made Zig auto-wrap into
    // `??U` on both the success AND failure paths: a failed inner
    // became a non-null outer holding a null inner, silently
    // reading as "success with null value" up in
    // `deserializeStruct`. Cursor Bugbot flagged this on #488 @
    // 2311b2d. The explicit `orelse return null` + `@as(T, v)`
    // makes both paths unambiguous.
    if (info == .optional) {
        if (value == .null_value) return @as(T, null);
        const inner = deserialize(info.optional.child, value, allocator) orelse return null;
        return @as(T, inner);
    }

    // Primitives — dispatch by `@typeInfo` tag rather than
    // enumerating every concrete width. Catches non-standard widths
    // (`u128`, `i48`, etc.) for free and keeps the code from going
    // stale if Zig grows new ones (cursor review on #496).
    if (info == .float) return valueToFloat(T, value);
    if (info == .int) return valueToInt(T, value);
    if (T == bool) return value.asBool();
    if (T == []const u8) {
        const s = value.asString() orelse return null;
        // Intern into the shared pool so (a) identical strings
        // dedupe and repeated prefab spawns don't leak, and (b)
        // allocations are batched through an arena instead of a
        // system call per string. See the intern pool docs at the
        // top of this file.
        return internString(s);
    }

    // Slices of other types (`[]const Struct`, `[]const []const u8`,
    // etc.). The `[]const u8` case is handled specifically above so
    // string deduplication still runs via the intern pool; this
    // branch covers everything else.
    //
    // Lifetime: the caller passes its per-world arena allocator
    // (see `applyComponent` in the scene bridge), which matches
    // the spawned entity's lifetime and resets on
    // `resetEcsBackend`. Prior revisions used the file-scope
    // `intern_arena`, which is never freed — slice contents aren't
    // deduplicable (unlike bare strings), so every prefab spawn
    // leaked a new allocation over the process lifetime. Using the
    // scene-scoped arena instead caps the cost at "one allocation
    // per entity per scene load," released on scene change.
    if (info == .pointer and info.pointer.size == .slice) {
        const arr = value.asArray() orelse return null;
        const Element = info.pointer.child;

        const buf = allocator.alloc(Element, arr.items.len) catch return null;
        for (arr.items, 0..) |item, i| {
            buf[i] = deserialize(Element, item, allocator) orelse return null;
        }
        return buf;
    }

    // Enums
    if (info == .@"enum") {
        const name = value.asString() orelse return null;
        return std.meta.stringToEnum(T, name);
    }

    // Tagged unions
    if (info == .@"union") {
        if (info.@"union".tag_type != null) {
            return deserializeTaggedUnion(T, value, allocator);
        }
        return null;
    }

    // EnumSet-like types
    if (info == .@"struct" and @hasDecl(T, "initEmpty") and @hasDecl(T, "insert")) {
        return deserializeEnumSet(T, value);
    }

    // Structs
    if (info == .@"struct") {
        return deserializeStruct(T, value, allocator);
    }

    return null;
}

fn valueToFloat(comptime T: type, value: Value) ?T {
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn valueToInt(comptime T: type, value: Value) ?T {
    return switch (value) {
        .integer => |i| std.math.cast(T, i),
        .float => |f| blk: {
            const rounded: i64 = @intFromFloat(f);
            break :blk std.math.cast(T, rounded);
        },
        else => null,
    };
}

fn deserializeStruct(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
    const obj = value.asObject() orelse return null;
    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;

    inline for (fields) |field| {
        if (obj.get(field.name)) |field_val| {
            if (deserialize(field.type, field_val, allocator)) |v| {
                @field(result, field.name) = v;
            } else if (field.default_value_ptr) |ptr| {
                const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
                @field(result, field.name) = default.*;
            } else {
                return null;
            }
        } else if (field.default_value_ptr) |ptr| {
            const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
            @field(result, field.name) = default.*;
        } else {
            return null;
        }
    }

    return result;
}

fn deserializeTaggedUnion(comptime T: type, value: Value, allocator: std.mem.Allocator) ?T {
    const obj = value.asObject() orelse return null;
    if (obj.entries.len != 1) return null;
    const entry = obj.entries[0];

    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, entry.key, field.name)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            }
            if (deserialize(field.type, entry.value, allocator)) |payload| {
                return @unionInit(T, field.name, payload);
            }
            return null;
        }
    }
    return null;
}

/// Deserialize an `EnumSet(K)` from a JSONC object whose entries are
/// `<enum_member>: <bool>` pairs. Strict on malformed input: returns
/// `null` if any value is not a bool *or* any key is not a member of
/// `K`. The lenient variant (silently dropping non-bool values and
/// unknown keys) was reverted because typos like `"FoodPaket": true`
/// failed open — the scene loaded with the flag missing and the bug
/// surfaced much later as wrong gameplay (e.g. a storage refusing
/// items it should accept). Returning `null` here lets the parent
/// struct's `default_value_ptr` fallback fire, or — if the field is
/// required — fails the load with a diagnostic at scene-load time.
/// See issue #497.
fn deserializeEnumSet(comptime T: type, value: Value) ?T {
    const obj = value.asObject() orelse return null;
    var set = T.initEmpty();
    for (obj.entries) |entry| {
        const is_true = entry.value.asBool() orelse return null;
        const key = std.meta.stringToEnum(T.Key, entry.key) orelse return null;
        if (is_true) set.insert(key);
    }
    return set;
}
