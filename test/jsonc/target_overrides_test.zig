//! Tests for `@ref`-targeted overrides (#801).
//!
//! A prefab reference's override map may carry `"@<ref>"` keys that
//! patch ref-named entities inside the referenced prefab's body —
//! component-field nested entities and prefab children alike,
//! recursively. Covered here:
//!
//!   - match via entry-level `ref` and via the nested prefab root's
//!     own `ref` (same precedence as ref registration),
//!   - match on prefab children (inline entities included),
//!   - multi-match fan-out (a ref used as a role),
//!   - reach through a sub-prefab (two levels down),
//!   - precedence: scene `@` patch beats the prefab body's own
//!     entry-level override (outermost author wins),
//!   - `null`-removal through a `@` patch (RFC #562 rides along),
//!   - hard errors: unmatched `@`, `@` on an inline entity,
//!     `"@name": null`, nested `@`-in-`@`,
//!   - flat-form / wrapped-form parity,
//!   - a cycle spliced in via a `@` patch is caught as `PrefabCycle`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Machine = struct {
    slots: []const u64 = &.{},
};

const Room = struct {
    workstations: []const u64 = &.{},
};

const Storage = struct {
    capacity: u32 = 5,
};

const NamespacedStorage = struct {
    capacity: u32 = 5,
};

const Components = engine.ComponentRegistry(.{
    .Machine = Machine,
    .Room = Room,
    .Storage = Storage,
    .industry__Storage = NamespacedStorage,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

// ── Helpers ────────────────────────────────────────────────────────

const PrefabFile = struct {
    name: []const u8,
    data: []const u8,
};

/// Write `prefabs` into a tmp dir and load `scene_src` against them.
fn loadWithPrefabs(game: *Game, prefabs: []const PrefabFile, scene_src: []const u8) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    for (prefabs) |p| {
        var buf: [128]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "prefabs/{s}.jsonc", .{p.name});
        try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = p.data });
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &path_buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{path_buf[0..len]});
    defer testing.allocator.free(prefab_path);
    try Bridge.loadSceneFromSource(game, scene_src, prefab_path);
}

/// Collect the capacities of every entity carrying `Storage`,
/// ascending, into `out`. Returns the slice actually filled.
fn storageCapacities(game: *Game, out: []u32) []u32 {
    var n: usize = 0;
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    while (view.next()) |e| {
        out[n] = game.ecs_backend.getComponent(e, Storage).?.capacity;
        n += 1;
    }
    std.mem.sort(u32, out[0..n], {}, std.sort.asc(u32));
    return out[0..n];
}

const machine_prefab =
    \\{ "Machine": { "slots": [
    \\    { "prefab": "storage_slot", "ref": "input" },
    \\    { "prefab": "storage_slot" }
    \\] } }
;

// Root-level `ref` — a nested entry without its own `ref` inherits it.
const storage_slot_prefab =
    \\{ "ref": "slot", "Storage": { "capacity": 5 } }
;

// ── Matching ───────────────────────────────────────────────────────

test "@ matches a component-array entry via the nested prefab root's ref" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": { "Storage": { "capacity": 12 } } }
        \\] }
    );

    var buf: [8]u32 = undefined;
    // Entry 1 has entry-level ref "input" (beats the root's "slot"),
    // so only entry 2 matches `@slot`.
    try testing.expectEqualSlices(u32, &.{ 5, 12 }, storageCapacities(&game, &buf));

    // The ref-array patch-back is unaffected by the fold.
    var view = game.ecs_backend.view(.{Machine}, .{});
    defer view.deinit();
    const m = game.ecs_backend.getComponent(view.next().?, Machine).?;
    try testing.expectEqual(@as(usize, 2), m.slots.len);
}

test "@ matches an entry-level ref" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@input": { "Storage": { "capacity": 3 } } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 5 }, storageCapacities(&game, &buf));
}

test "@ matches an inline prefab child" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "house",
            .data =
            \\{ "children": [
            \\  { "ref": "door", "components": { "Storage": { "capacity": 1 } } }
            \\] }
            ,
        },
    },
        \\{ "children": [
        \\  { "prefab": "house", "@door": { "Storage": { "capacity": 9 } } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{9}, storageCapacities(&game, &buf));
}

test "@ fans out to every entity sharing the ref" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "machine2",
            .data =
            \\{ "Machine": { "slots": [
            \\    { "prefab": "storage_slot", "ref": "buffer" },
            \\    { "prefab": "storage_slot", "ref": "buffer" },
            \\    { "prefab": "storage_slot", "ref": "buffer" }
            \\] } }
            ,
        },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine2", "@buffer": { "Storage": { "capacity": 12 } } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 12, 12, 12 }, storageCapacities(&game, &buf));
}

test "@ reaches through a sub-prefab (two levels down)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "room",
            .data =
            \\{ "Room": { "workstations": [ { "prefab": "machine" } ] } }
            ,
        },
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "room", "@slot": { "Storage": { "capacity": 12 } } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 5, 12 }, storageCapacities(&game, &buf));
}

test "@ does not leak into sibling instances" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": { "Storage": { "capacity": 12 } } },
        \\  { "prefab": "machine" }
        \\] }
    );
    var buf: [8]u32 = undefined;
    // Machine 1: input 5 + slot 12. Machine 2: untouched 5 + 5.
    try testing.expectEqualSlices(u32, &.{ 5, 5, 5, 12 }, storageCapacities(&game, &buf));
}

// ── Precedence + merge semantics ───────────────────────────────────

test "scene @ patch beats the prefab body's own entry-level override" {
    const machine3 =
        \\{ "Machine": { "slots": [
        \\    { "prefab": "storage_slot", "ref": "out2", "Storage": { "capacity": 7 } }
        \\] } }
    ;
    // Control: the body's own override applies without a scene patch.
    {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        try loadWithPrefabs(&game, &.{
            .{ .name = "machine3", .data = machine3 },
            .{ .name = "storage_slot", .data = storage_slot_prefab },
        },
            \\{ "children": [ { "prefab": "machine3" } ] }
        );
        var buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, &.{7}, storageCapacities(&game, &buf));
    }
    // The scene's @ patch is the outermost author — it wins.
    {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        try loadWithPrefabs(&game, &.{
            .{ .name = "machine3", .data = machine3 },
            .{ .name = "storage_slot", .data = storage_slot_prefab },
        },
            \\{ "children": [
            \\  { "prefab": "machine3", "@out2": { "Storage": { "capacity": 12 } } }
            \\] }
        );
        var buf: [8]u32 = undefined;
        try testing.expectEqualSlices(u32, &.{12}, storageCapacities(&game, &buf));
    }
}

test "a null component inside a @ patch removes it from the target" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "house",
            .data =
            \\{ "children": [
            \\  { "ref": "door", "components": { "Storage": { "capacity": 1 } } }
            \\] }
            ,
        },
    },
        \\{ "children": [
        \\  { "prefab": "house", "@door": { "Storage": null } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), storageCapacities(&game, &buf).len);
}

test "wrapped-form overrides carry @ keys identically" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "overrides": {
        \\      "@slot": { "Storage": { "capacity": 12 } }
        \\  } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 5, 12 }, storageCapacities(&game, &buf));
}

// ── Hard errors ────────────────────────────────────────────────────

test "an unmatched @ target is a load-time error" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@nosuch": { "Storage": { "capacity": 12 } } }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

test "@ on an inline entity is a load-time error" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{},
        \\{ "children": [
        \\  { "Storage": { "capacity": 1 }, "@x": { "Storage": { "capacity": 2 } } }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

test "removing a whole target entity via @: null is rejected" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": null }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

test "nested @ inside a @ patch is rejected" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": { "@deeper": { "Storage": {} } } }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

// ── Cycle safety ───────────────────────────────────────────────────

test "a cycle spliced in via a @ patch is caught as PrefabCycle" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{
            .name = "a",
            .data =
            \\{ "Machine": { "slots": [ { "prefab": "b" } ] } }
            ,
        },
        .{
            .name = "b",
            .data =
            \\{ "ref": "hole", "Storage": { "capacity": 5 } }
            ,
        },
    },
        // The @ patch replaces b's (empty) Machine with one whose
        // slots reference `a` again — a cycle only visible on the
        // patched tree.
        \\{ "children": [
        \\  { "prefab": "a", "@hole": { "Machine": { "slots": [ { "prefab": "a" } ] } } }
        \\] }
    );
    try testing.expectError(error.PrefabCycle, result);
}

// ── Regression: the pre-@ workarounds keep working ─────────────────

test "array restatement in a scene override still works (the pre-@ workaround)" {
    // Verified against v2.10.0 before this feature: a scene may
    // restate a prefab's entity-bearing array outright (arrays
    // replace in mergeValues), with entry-level overrides on the
    // restated entries. The @ fold sits upstream of that path now —
    // this pins that it changed nothing.
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine",
        \\    "Machine": { "slots": [
        \\      { "prefab": "storage_slot", "ref": "input" },
        \\      { "prefab": "storage_slot", "Storage": { "capacity": 12 } }
        \\    ] } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 5, 12 }, storageCapacities(&game, &buf));

    var view = game.ecs_backend.view(.{Machine}, .{});
    defer view.deinit();
    const m = game.ecs_backend.getComponent(view.next().?, Machine).?;
    try testing.expectEqual(@as(usize, 2), m.slots.len);
}

test "an override-only bare component still attaches to the root (now warned, #801)" {
    // The original trap's BEHAVIOR is unchanged — adding a component
    // to the reference root stays legal — it just warns now when a
    // nested entity carries the component. This pins the behavior;
    // the warning is a log line.
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "machine", "Storage": { "capacity": 12 } }
        \\] }
    );

    var view = game.ecs_backend.view(.{Machine}, .{});
    defer view.deinit();
    const machine = view.next().?;
    const root_storage = game.ecs_backend.getComponent(machine, Storage) orelse return error.TestExpectedEntity;
    try testing.expectEqual(@as(u32, 12), root_storage.capacity);
    // Nested slots keep their defaults — the override did NOT reach them.
    const m = game.ecs_backend.getComponent(machine, Machine).?;
    for (m.slots) |sid| {
        const s = game.ecs_backend.getComponent(@intCast(sid), Storage).?;
        try testing.expectEqual(@as(u32, 5), s.capacity);
    }
}

// ── Round 2 (bot-review hardening) ─────────────────────────────────

test "a bare data key inside a @ patch is rejected" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        // `capacity` is component DATA, not a component — applying it
        // would silently no-op. Hard error with a did-you-mean.
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": { "capacity": 12 } }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

test "a pack-namespaced component key inside a @ patch is accepted" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "nmachine",
            .data =
            \\{ "Machine": { "slots": [ { "prefab": "nslot" } ] } }
            ,
        },
        .{
            // Namespaced keys start lowercase, so the wrapped form is
            // required prefab-side (flat keeps PascalCase + `@` only).
            .name = "nslot",
            .data =
            \\{ "ref": "nslot", "components": { "industry__Storage": { "capacity": 5 } } }
            ,
        },
    },
        \\{ "children": [
        \\  { "prefab": "nmachine", "@nslot": { "industry__Storage": { "capacity": 12 } } }
        \\] }
    );
    var view = game.ecs_backend.view(.{NamespacedStorage}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    try testing.expectEqual(@as(u32, 12), game.ecs_backend.getComponent(e, NamespacedStorage).?.capacity);
    try testing.expect(view.next() == null);
}

test "prefab-root @ keys are skipped without spawning or cycling" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    // The root-level `@junk` even references the prefab itself — the
    // loader must neither spawn from it nor report a cycle, because
    // that content is never instantiated. Exercises BOTH the merged
    // path (entry with overrides) and the no-patch early return.
    const selfy =
        \\{ "Storage": { "capacity": 3 },
        \\  "@junk": { "Machine": { "slots": [ { "prefab": "selfy" } ] } } }
    ;
    try loadWithPrefabs(&game, &.{.{ .name = "selfy", .data = selfy }},
        \\{ "children": [
        \\  { "prefab": "selfy" },
        \\  { "prefab": "selfy", "Storage": { "capacity": 4 } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, storageCapacities(&game, &buf));
    var view = game.ecs_backend.view(.{Machine}, .{});
    defer view.deinit();
    try testing.expect(view.next() == null);
}

test "runtime spawnFromPrefab fails loudly (and cleanly) on an unmatched @ in the body" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/machine.jsonc",
        .data = machine_prefab,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/storage_slot.jsonc",
        .data = storage_slot_prefab,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/broken.jsonc",
        .data =
        \\{ "children": [
        \\  { "prefab": "machine", "@nosuch": { "Storage": { "capacity": 12 } } }
        \\] }
        ,
    });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &path_buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{path_buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [] }
    , prefab_path);

    try testing.expect(game.spawnFromPrefab("broken", .{ .x = 0, .y = 0 }) == null);
    // Nothing half-built stays behind: no Storage entities linger.
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    try testing.expect(view.next() == null);
}

test "a namespaced-looking key with a non-Pascal suffix is rejected" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const result = loadWithPrefabs(&game, &.{
        .{ .name = "machine", .data = machine_prefab },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        // `capacity__oops` has the namespace delimiter but no Pascal
        // suffix — it can never match a registered component, so
        // accepting it would be a silent no-op (codex round 3).
        \\{ "children": [
        \\  { "prefab": "machine", "@slot": { "capacity__oops": 12 } }
        \\] }
    );
    try testing.expectError(error.InvalidFormat, result);
}

test "@ works against a root-wrapped (unified v1.x) prefab" {
    // `{ "root": { ... } }` files must unwrap on every path — the
    // diagnostic walk included (codex round 3).
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadWithPrefabs(&game, &.{
        .{
            .name = "wrapped",
            .data =
            \\{ "root": { "Machine": { "slots": [
            \\    { "prefab": "storage_slot" }
            \\] } } }
            ,
        },
        .{ .name = "storage_slot", .data = storage_slot_prefab },
    },
        \\{ "children": [
        \\  { "prefab": "wrapped", "@slot": { "Storage": { "capacity": 12 } } }
        \\] }
    );
    var buf: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{12}, storageCapacities(&game, &buf));
}
