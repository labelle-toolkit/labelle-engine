//! Direct tests for `src/jsonc/deserializer.zig`. The existing
//! `jsonc_bridge_deserialize_test.zig` exercises the deserializer
//! via the full scene-load path (component spawned on a Game,
//! retrieved via the ECS view). This file targets the same
//! function but drives it directly with synthetic `Value` literals
//! — faster, fewer dependencies, easier to pin a single edge case.
//!
//! Added as part of #495 slice 5 alongside the loader split, so
//! the smaller pieces gain dedicated coverage as they leave the
//! monolith.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const deserializer = engine.jsonc_deserializer;
const SceneValue = engine.SceneValue;

// ── Primitive types ────────────────────────────────────────────

test "deserialize: integer to f32" {
    const v = SceneValue{ .integer = 7 };
    try testing.expectEqual(@as(f32, 7), deserializer.deserialize(f32, v, testing.allocator).?);
}

test "deserialize: float to f32" {
    const v = SceneValue{ .float = 1.5 };
    try testing.expectEqual(@as(f32, 1.5), deserializer.deserialize(f32, v, testing.allocator).?);
}

test "deserialize: integer to i32 (in range)" {
    const v = SceneValue{ .integer = -5 };
    try testing.expectEqual(@as(i32, -5), deserializer.deserialize(i32, v, testing.allocator).?);
}

test "deserialize: integer to u8 (out of range returns null)" {
    const v = SceneValue{ .integer = 300 };
    try testing.expect(deserializer.deserialize(u8, v, testing.allocator) == null);
}

test "deserialize: bool" {
    const t = SceneValue{ .boolean = true };
    const f = SceneValue{ .boolean = false };
    try testing.expect(deserializer.deserialize(bool, t, testing.allocator).?);
    try testing.expect(!deserializer.deserialize(bool, f, testing.allocator).?);
}

test "deserialize: string interns identical values" {
    const a = SceneValue{ .string = "shared.png" };
    const b = SceneValue{ .string = "shared.png" };
    const sa = deserializer.deserialize([]const u8, a, testing.allocator).?;
    const sb = deserializer.deserialize([]const u8, b, testing.allocator).?;
    // Same intern bucket => identical pointer.
    try testing.expectEqual(sa.ptr, sb.ptr);
    try testing.expectEqualStrings("shared.png", sa);
}

// ── Optionals — the three-paths-of-`null` contract ─────────────

test "deserialize: optional gets JSONC null → success with null inner" {
    const v = SceneValue{ .null_value = {} };
    const got = deserializer.deserialize(?i32, v, testing.allocator);
    // Outer Optional is non-null (deserialize succeeded); inner
    // Optional unwraps to null.
    try testing.expect(got != null);
    try testing.expect(got.? == null);
}

test "deserialize: optional gets valid value → success with that value" {
    const v = SceneValue{ .integer = 42 };
    const got = deserializer.deserialize(?i32, v, testing.allocator);
    try testing.expect(got != null);
    try testing.expectEqual(@as(i32, 42), got.?.?);
}

test "deserialize: optional gets malformed value → outer null (failure propagates)" {
    // `?i32` receives a string — type mismatch on the inner type.
    // The bug Cursor Bugbot caught in #488 was that this case
    // returned `?(null)` instead of bare `null`, silently masking
    // the failure as "success with null." Lock it down.
    const v = SceneValue{ .string = "not a number" };
    const got = deserializer.deserialize(?i32, v, testing.allocator);
    try testing.expect(got == null);
}

// ── Enums ──────────────────────────────────────────────────────

const Color = enum { red, green, blue };

test "deserialize: enum from string" {
    const v = SceneValue{ .string = "green" };
    try testing.expectEqual(Color.green, deserializer.deserialize(Color, v, testing.allocator).?);
}

test "deserialize: enum from unknown string returns null" {
    const v = SceneValue{ .string = "yellow" };
    try testing.expect(deserializer.deserialize(Color, v, testing.allocator) == null);
}

// ── Slices ─────────────────────────────────────────────────────

test "deserialize: []const i32 from JSONC array" {
    const items = [_]SceneValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    const v = SceneValue{ .array = .{ .items = @constCast(&items) } };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = deserializer.deserialize([]const i32, v, arena.allocator()).?;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(i32, 1), got[0]);
    try testing.expectEqual(@as(i32, 2), got[1]);
    try testing.expectEqual(@as(i32, 3), got[2]);
}

test "deserialize: empty slice" {
    const items = [_]SceneValue{};
    const v = SceneValue{ .array = .{ .items = @constCast(&items) } };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = deserializer.deserialize([]const i32, v, arena.allocator()).?;
    try testing.expectEqual(@as(usize, 0), got.len);
}

// ── Structs ────────────────────────────────────────────────────

const Tile = struct {
    x: i32 = 0,
    y: i32 = 0,
    walkable: bool = true,
};

test "deserialize: struct with all fields present" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "x", .value = .{ .integer = 5 } },
        .{ .key = "y", .value = .{ .integer = 7 } },
        .{ .key = "walkable", .value = .{ .boolean = false } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const got = deserializer.deserialize(Tile, v, testing.allocator).?;
    try testing.expectEqual(@as(i32, 5), got.x);
    try testing.expectEqual(@as(i32, 7), got.y);
    try testing.expect(!got.walkable);
}

test "deserialize: struct missing field uses default" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "x", .value = .{ .integer = 9 } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const got = deserializer.deserialize(Tile, v, testing.allocator).?;
    try testing.expectEqual(@as(i32, 9), got.x);
    // y / walkable fall back to declared defaults.
    try testing.expectEqual(@as(i32, 0), got.y);
    try testing.expect(got.walkable);
}

const Required = struct {
    name: []const u8,
};

test "deserialize: struct missing field with no default returns null" {
    var entries = [_]SceneValue.Object.Entry{};
    const v = SceneValue{ .object = .{ .entries = &entries } };

    try testing.expect(deserializer.deserialize(Required, v, testing.allocator) == null);
}

// ── Tagged unions ──────────────────────────────────────────────

const Shape = union(enum) {
    circle: struct { radius: f32 = 1 },
    square: struct { size: f32 = 1 },
    point: void,
};

test "deserialize: tagged union with payload" {
    var inner_entries = [_]SceneValue.Object.Entry{
        .{ .key = "radius", .value = .{ .float = 3.5 } },
    };
    var outer_entries = [_]SceneValue.Object.Entry{
        .{ .key = "circle", .value = .{ .object = .{ .entries = &inner_entries } } },
    };
    const v = SceneValue{ .object = .{ .entries = &outer_entries } };

    const got = deserializer.deserialize(Shape, v, testing.allocator).?;
    try testing.expect(got == .circle);
    try testing.expectEqual(@as(f32, 3.5), got.circle.radius);
}

test "deserialize: tagged union with void payload" {
    var inner_entries = [_]SceneValue.Object.Entry{};
    var outer_entries = [_]SceneValue.Object.Entry{
        .{ .key = "point", .value = .{ .object = .{ .entries = &inner_entries } } },
    };
    const v = SceneValue{ .object = .{ .entries = &outer_entries } };

    const got = deserializer.deserialize(Shape, v, testing.allocator).?;
    try testing.expect(got == .point);
}

// ── EnumSet ────────────────────────────────────────────────────

const Items = enum { water, vegetable, meat };

test "deserialize: EnumSet from object of bools" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "water", .value = .{ .boolean = true } },
        .{ .key = "meat", .value = .{ .boolean = true } },
        .{ .key = "vegetable", .value = .{ .boolean = false } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const Set = std.EnumSet(Items);
    const got = deserializer.deserialize(Set, v, testing.allocator).?;
    try testing.expect(got.contains(.water));
    try testing.expect(got.contains(.meat));
    try testing.expect(!got.contains(.vegetable));
}

// Strict-on-malformed contract — see issue #497. The lenient variant
// silently dropped bad entries; that meant a typo like
// `"vegtable": true` produced an empty set and surfaced as a
// gameplay bug far from the source. These tests pin the strict
// behavior: any malformed entry => null, so the parent struct's
// default fires (or scene load fails loudly at parse time).

test "deserialize: EnumSet rejects non-bool value" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "water", .value = .{ .string = "yes" } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const Set = std.EnumSet(Items);
    try testing.expect(deserializer.deserialize(Set, v, testing.allocator) == null);
}

test "deserialize: EnumSet rejects unknown enum key" {
    var entries = [_]SceneValue.Object.Entry{
        // typo: `vegtable` instead of `vegetable`
        .{ .key = "vegtable", .value = .{ .boolean = true } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const Set = std.EnumSet(Items);
    try testing.expect(deserializer.deserialize(Set, v, testing.allocator) == null);
}

test "deserialize: EnumSet rejects mixed valid + invalid entries" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "water", .value = .{ .boolean = true } },
        // unknown key — should poison the whole set
        .{ .key = "diamond", .value = .{ .boolean = true } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const Set = std.EnumSet(Items);
    try testing.expect(deserializer.deserialize(Set, v, testing.allocator) == null);
}

test "deserialize: EnumSet all-valid bools (mixed true/false) produces expected set" {
    var entries = [_]SceneValue.Object.Entry{
        .{ .key = "water", .value = .{ .boolean = true } },
        .{ .key = "vegetable", .value = .{ .boolean = false } },
        .{ .key = "meat", .value = .{ .boolean = true } },
    };
    const v = SceneValue{ .object = .{ .entries = &entries } };

    const Set = std.EnumSet(Items);
    const got = deserializer.deserialize(Set, v, testing.allocator).?;
    try testing.expect(got.contains(.water));
    try testing.expect(!got.contains(.vegetable));
    try testing.expect(got.contains(.meat));
}
