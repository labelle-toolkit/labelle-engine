//! `spawnFromPrefab` integration tests.
//!
//! Exercises the prefab-instantiation → PrefabInstance/PrefabChild
//! tagging pipeline added in Slice 2 of the save/load-for-prefabs
//! RFC. Uses `engine.Game` + `JsoncSceneBridge` + a tmp-dir scene
//! jsonc to get a realistic prefab-cache setup.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Health = struct {
    current: f32 = 100,
    max: f32 = 100,
};

const Components = engine.ComponentRegistry(.{
    .Health = Health,
});

const Bridge = engine.JsoncSceneBridge(engine.Game, Components);
const PrefabInstance = engine.Game.PrefabInstanceComp;
const PrefabChild = engine.Game.PrefabChildComp;

/// Fixture bundles the Game with the heap-allocated `prefab_dir`
/// path that its prefab cache borrows. Freeing the path while the
/// game is still alive dangles the cache's borrow, so both die
/// together in `deinit`.
const TestFixture = struct {
    game: engine.Game,
    prefab_dir: []const u8,

    fn deinit(self: *TestFixture) void {
        self.game.deinit();
        testing.allocator.free(self.prefab_dir);
    }
};

fn bootGameWithPrefab(
    tmp_dir: *std.testing.TmpDir,
    prefab_name: []const u8,
    prefab_source: []const u8,
) !TestFixture {
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);

    const prefab_sub = try std.fmt.allocPrint(testing.allocator, "prefabs/{s}.jsonc", .{prefab_name});
    defer testing.allocator.free(prefab_sub);
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = prefab_sub, .data = prefab_source });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const _len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const dir_path = buf[0.._len];
    const prefab_dir = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{dir_path});
    errdefer testing.allocator.free(prefab_dir);

    var game = engine.Game.init(testing.allocator);
    errdefer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [] }
    , prefab_dir);

    return .{ .game = game, .prefab_dir = prefab_dir };
}

test "spawnFromPrefab: tags root with PrefabInstance { path }" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try bootGameWithPrefab(&tmp_dir, "bare",
        \\{
        \\  "components": { "Health": { "current": 75, "max": 100 } }
        \\}
    );
    defer fixture.deinit();

    const entity = fixture.game.spawnFromPrefab("bare", .{ .x = 10, .y = 20 }).?;

    const h = fixture.game.ecs_backend.getComponent(entity, Health).?;
    try testing.expectApproxEqAbs(@as(f32, 75), h.current, 0.01);

    const pi = fixture.game.ecs_backend.getComponent(entity, PrefabInstance).?;
    try testing.expectEqualStrings("bare", pi.path);
    try testing.expectEqualStrings("", pi.overrides);
}

test "spawnFromPrefab: returns null for unknown prefab name" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try bootGameWithPrefab(&tmp_dir, "bare",
        \\{
        \\  "components": { "Health": {} }
        \\}
    );
    defer fixture.deinit();

    const result = fixture.game.spawnFromPrefab("not_a_prefab", .{ .x = 0, .y = 0 });
    try testing.expect(result == null);
}

test "spawnFromPrefab: tags children with PrefabChild { root, local_path }" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Prefab with two children; the second has a grand-child.
    // Expected local_paths:
    //   child 0:                       children[0]
    //   child 1:                       children[1]
    //   child 1 → grand-child 0:       children[1].children[0]
    var fixture = try bootGameWithPrefab(&tmp_dir, "tree",
        \\{
        \\  "components": { "Health": { "current": 100, "max": 100 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 10, "max": 10 } } },
        \\    {
        \\      "components": { "Health": { "current": 20, "max": 20 } },
        \\      "children": [
        \\        { "components": { "Health": { "current": 30, "max": 30 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    const root = fixture.game.spawnFromPrefab("tree", .{ .x = 0, .y = 0 }).?;
    const root_id: u32 = @intCast(root);

    var found_c0 = false;
    var found_c1 = false;
    var found_c1_gc0 = false;
    var tagged_count: usize = 0;

    var view = fixture.game.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        tagged_count += 1;
        const pc = fixture.game.ecs_backend.getComponent(ent, PrefabChild).?;
        try testing.expectEqual(root_id, @as(u32, @intCast(pc.root)));
        if (std.mem.eql(u8, pc.local_path, "children[0]")) {
            found_c0 = true;
        } else if (std.mem.eql(u8, pc.local_path, "children[1]")) {
            found_c1 = true;
        } else if (std.mem.eql(u8, pc.local_path, "children[1].children[0]")) {
            found_c1_gc0 = true;
        }
    }

    try testing.expectEqual(@as(usize, 3), tagged_count);
    try testing.expect(found_c0);
    try testing.expect(found_c1);
    try testing.expect(found_c1_gc0);

    // The root itself has PrefabInstance (not PrefabChild).
    const pi = fixture.game.ecs_backend.getComponent(root, PrefabInstance).?;
    try testing.expectEqualStrings("tree", pi.path);
    try testing.expect(!fixture.game.ecs_backend.hasComponent(root, PrefabChild));
}

test "spawnFromPrefab: multiple spawns get independent roots" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try bootGameWithPrefab(&tmp_dir, "unit",
        \\{
        \\  "components": { "Health": { "current": 50, "max": 50 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 5, "max": 5 } } }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    const a = fixture.game.spawnFromPrefab("unit", .{ .x = 0, .y = 0 }).?;
    const b = fixture.game.spawnFromPrefab("unit", .{ .x = 50, .y = 50 }).?;
    try testing.expect(a != b);

    try testing.expect(fixture.game.ecs_backend.hasComponent(a, PrefabInstance));
    try testing.expect(fixture.game.ecs_backend.hasComponent(b, PrefabInstance));

    const a_id: u32 = @intCast(a);
    const b_id: u32 = @intCast(b);
    var a_children: usize = 0;
    var b_children: usize = 0;

    var view = fixture.game.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const pc = fixture.game.ecs_backend.getComponent(ent, PrefabChild).?;
        const root_id: u32 = @intCast(pc.root);
        if (root_id == a_id) a_children += 1;
        if (root_id == b_id) b_children += 1;
    }

    try testing.expectEqual(@as(usize, 1), a_children);
    try testing.expectEqual(@as(usize, 1), b_children);
}

// ── #844: children-only prefab roots ────────────────────────────
//
// `uf.prefabComponents` documents `null` as "this root declares no
// components" — a root carrying only `"children"` is well-formed per
// RFC #596. `spawnPrefabImpl` used to collapse that `null` into the
// same `return null` it uses for "prefab not found", so a purely
// visual dressing prefab spawned fine from a scene but never at
// runtime. Save/load Phase 1a respawns through the runtime path, so
// the whole subtree came back missing after a load
// (Flying-Platform/flying-platform-labelle#857).

test "spawnFromPrefab: #844 root with ONLY children spawns with its children" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // No `components` wrapper and no flat PascalCase keys at the
    // root — the exact shape of a bare anchor + sprite children.
    var fixture = try bootGameWithPrefab(&tmp_dir, "dressing",
        \\{
        \\  "children": [
        \\    { "components": { "Health": { "current": 11, "max": 11 } } },
        \\    { "components": { "Health": { "current": 22, "max": 22 } } },
        \\    {
        \\      "components": { "Health": { "current": 33, "max": 33 } },
        \\      "children": [
        \\        { "components": { "Health": { "current": 44, "max": 44 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    // 1. The spawn must SUCCEED — `null` here is the bug.
    const root = fixture.game.spawnFromPrefab("dressing", .{ .x = 10, .y = 20 }) orelse {
        std.debug.print("spawnFromPrefab returned null for a children-only prefab (#844)\n", .{});
        return error.TestUnexpectedResult;
    };

    // 2. The root is still tagged as a prefab instance, so save/load
    //    Phase 1a can re-instantiate it from the path.
    const pi = fixture.game.ecs_backend.getComponent(root, PrefabInstance).?;
    try testing.expectEqualStrings("dressing", pi.path);
    try testing.expect(!fixture.game.ecs_backend.hasComponent(root, PrefabChild));

    // 3. Every child (and grand-child) exists, is tagged `PrefabChild`
    //    with THIS root, and carries its component. Phase 1b matches
    //    saved children to respawned ones by `local_path`, so those
    //    paths are the save/load contract, not a detail.
    var found = [_]bool{false} ** 4;
    var tagged: usize = 0;

    var view = fixture.game.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        tagged += 1;
        const pc = fixture.game.ecs_backend.getComponent(ent, PrefabChild).?;
        try testing.expectEqual(@as(u32, @intCast(root)), @as(u32, @intCast(pc.root)));
        const h = fixture.game.ecs_backend.getComponent(ent, Health).?;
        if (std.mem.eql(u8, pc.local_path, "children[0]")) {
            found[0] = true;
            try testing.expectApproxEqAbs(@as(f32, 11), h.current, 0.01);
        } else if (std.mem.eql(u8, pc.local_path, "children[1]")) {
            found[1] = true;
            try testing.expectApproxEqAbs(@as(f32, 22), h.current, 0.01);
        } else if (std.mem.eql(u8, pc.local_path, "children[2]")) {
            found[2] = true;
            try testing.expectApproxEqAbs(@as(f32, 33), h.current, 0.01);
        } else if (std.mem.eql(u8, pc.local_path, "children[2].children[0]")) {
            found[3] = true;
            try testing.expectApproxEqAbs(@as(f32, 44), h.current, 0.01);
        }
    }

    try testing.expectEqual(@as(usize, 4), tagged);
    for (found) |f| try testing.expect(f);
}
