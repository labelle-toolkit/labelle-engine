//! SpriteByField state machine tests. Covers the lookup table +
//! save-policy contract. The ECS tick system that reads the runtime
//! field value and mutates the Sprite lands in a follow-up.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const SpriteByField = engine.SpriteByField;

// Hydroponics plant as the canonical example: level 0/1 hide the
// overlay, levels 2–5 select increasingly advanced growth sprites.
const plant_entries = [_]SpriteByField.Entry{
    .{ .key = 0, .sprite_name = null },
    .{ .key = 1, .sprite_name = null },
    .{ .key = 2, .sprite_name = "nursery_sapling_lvl1.png" },
    .{ .key = 3, .sprite_name = "nursery_sapling_lvl2.png" },
    .{ .key = 4, .sprite_name = "nursery_green_lvl1.png" },
    .{ .key = 5, .sprite_name = "nursery_green_lvl2.png" },
};

fn plantTable() SpriteByField {
    return .{
        .component = "TendableWorkstation",
        .field = "level",
        .source = .parent,
        .entries = &plant_entries,
    };
}

test "SpriteByField: lookup resolves each configured key" {
    const table = plantTable();

    try testing.expectEqualStrings("nursery_sapling_lvl1.png", table.lookup(2).match.?);
    try testing.expectEqualStrings("nursery_sapling_lvl2.png", table.lookup(3).match.?);
    try testing.expectEqualStrings("nursery_green_lvl1.png", table.lookup(4).match.?);
    try testing.expectEqualStrings("nursery_green_lvl2.png", table.lookup(5).match.?);
}

test "SpriteByField: null sprite_name means hide" {
    const table = plantTable();

    // Levels 0 and 1 match the table but have null sprite_name —
    // tick system should interpret as "hide the sprite."
    const r0 = table.lookup(0);
    try testing.expect(r0 == .match);
    try testing.expect(r0.match == null);

    const r1 = table.lookup(1);
    try testing.expect(r1 == .match);
    try testing.expect(r1.match == null);
}

test "SpriteByField: unmapped key returns .no_match" {
    const table = plantTable();

    try testing.expect(table.lookup(-1) == .no_match);
    try testing.expect(table.lookup(6) == .no_match);
    try testing.expect(table.lookup(100) == .no_match);
}

test "SpriteByField: signed keys supported (sentinel values)" {
    // Games using `-1` as "Unset" / "None" sentinels (per gemini
    // review on RFC #472) should round-trip negative keys unchanged.
    const entries = [_]SpriteByField.Entry{
        .{ .key = -1, .sprite_name = "unset.png" },
        .{ .key = 0, .sprite_name = "zero.png" },
        .{ .key = 1, .sprite_name = "one.png" },
    };
    const table = SpriteByField{
        .component = "Foo",
        .field = "bar",
        .entries = &entries,
    };

    try testing.expectEqualStrings("unset.png", table.lookup(-1).match.?);
    try testing.expectEqualStrings("zero.png", table.lookup(0).match.?);
    try testing.expectEqualStrings("one.png", table.lookup(1).match.?);
    try testing.expect(table.lookup(-2) == .no_match);
}

test "SpriteByField: empty entries table is all .no_match" {
    const empty: []const SpriteByField.Entry = &.{};
    const table = SpriteByField{
        .component = "Foo",
        .field = "bar",
        .entries = empty,
    };

    try testing.expect(table.lookup(0) == .no_match);
    try testing.expect(table.lookup(-1) == .no_match);
}

test "SpriteByField: first-match-wins on duplicate keys" {
    // Duplicate keys are a prefab-authoring bug, not an engine
    // invariant — but the resolution rule is worth pinning so a
    // future micro-optimisation doesn't accidentally change it.
    const entries = [_]SpriteByField.Entry{
        .{ .key = 42, .sprite_name = "first.png" },
        .{ .key = 42, .sprite_name = "second.png" },
    };
    const table = SpriteByField{
        .component = "Foo",
        .field = "bar",
        .entries = &entries,
    };

    try testing.expectEqualStrings("first.png", table.lookup(42).match.?);
}

test "SpriteByField: save policy is saveable with runtime cache skipped" {
    try testing.expect(core.hasSavePolicy(SpriteByField));
    try testing.expectEqual(core.SavePolicy.saveable, core.getSavePolicy(SpriteByField).?);

    // `last_key_set` and `last_key` form the steady-state cache the
    // tick system uses to skip `markVisualDirty` when nothing
    // changed. They must stay out of the save file — restoring a
    // stale cache would mask a legitimate sprite update on the
    // first post-load tick.
    const skip = core.getSkipFields(SpriteByField);
    var has_last_key_set = false;
    var has_last_key = false;
    for (skip) |name| {
        if (std.mem.eql(u8, name, "last_key_set")) has_last_key_set = true;
        if (std.mem.eql(u8, name, "last_key")) has_last_key = true;
    }
    try testing.expect(has_last_key_set);
    try testing.expect(has_last_key);
}

test "SpriteByField: default source is .self" {
    const table = SpriteByField{
        .component = "Foo",
        .field = "bar",
        .entries = &.{},
    };
    // Explicit-default regression guard: the hydroponics migration
    // relies on `.parent` being set explicitly in the prefab, so
    // silently defaulting existing `.self` usage to `.parent` would
    // break downstream games that have started tagging their own
    // components.
    try testing.expectEqual(engine.SpriteByFieldSource.self, table.source);
}
