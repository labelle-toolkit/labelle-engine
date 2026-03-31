/// Tests for scene entity cross-references (@ref syntax).
///
/// Verifies that entities can declare "ref" names and reference each other
/// via @name strings in entity_ref fields. The scene bridge resolves these
/// in a two-pass load: pass 1 creates entities and collects refs, pass 2
/// patches deferred components with resolved entity IDs.
const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

// ── Test component types ────────────────────────────────────────────

/// Simulates an item stored in a container (like Stored in flying-platform).
const StoredIn = struct {
    pub const save = core.Saveable(.saveable, @This(), .{
        .entity_refs = &.{"container_id"},
    });
    container_id: u64 = 0,
};

/// Simulates a container holding an item (like WithItem in flying-platform).
const HoldsItem = struct {
    pub const save = core.Saveable(.saveable, @This(), .{
        .entity_refs = &.{"item_id"},
    });
    item_id: u64 = 0,
};

/// Simple marker component (no entity refs).
const Health = struct {
    current: f32 = 100,
    max: f32 = 100,
};

/// Component with multiple entity refs.
const Link = struct {
    pub const save = core.Saveable(.saveable, @This(), .{
        .entity_refs = &.{ "source", "target" },
    });
    source: u64 = 0,
    target: u64 = 0,
};

const Components = engine.ComponentRegistry(.{
    .StoredIn = StoredIn,
    .HoldsItem = HoldsItem,
    .Health = Health,
    .Link = Link,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

// ── Helpers ─────────────────────────────────────────────────────────

fn tmpPath(tmp_dir: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, sub });
}

fn loadSource(game: *Game, source: []const u8) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("prefabs");
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);
    try Bridge.loadSceneFromSource(game, source, prefab_path);
}

// ── Tests ───────────────────────────────────────────────────────────

test "@ref: basic bidirectional cross-reference" {
    // Container and item reference each other
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "ref": "box", "components": { "HoldsItem": { "item_id": "@apple" } } },
        \\    { "ref": "apple", "components": { "StoredIn": { "container_id": "@box" } } }
        \\  ]
        \\}
    );

    // Find entities by iterating (first entity has HoldsItem, second has StoredIn)
    const Entity = Game.EntityType;
    var holder: ?Entity = null;
    var stored: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{HoldsItem}, .{});
        if (view.next()) |e| holder = e;
        view.deinit();
    }
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored = e;
        view.deinit();
    }

    try testing.expect(holder != null);
    try testing.expect(stored != null);

    const holds = game.ecs_backend.getComponent(holder.?, HoldsItem).?;
    const stored_in = game.ecs_backend.getComponent(stored.?, StoredIn).?;

    // Cross-references should point at each other
    try testing.expectEqual(@as(u64, @intCast(stored.?)), holds.item_id);
    try testing.expectEqual(@as(u64, @intCast(holder.?)), stored_in.container_id);
}

test "@ref: forward reference (referenced entity declared after)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // apple references box, but box is declared AFTER apple
    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "ref": "apple", "components": { "StoredIn": { "container_id": "@box" } } },
        \\    { "ref": "box", "components": { "Health": { "current": 50, "max": 50 } } }
        \\  ]
        \\}
    );

    const Entity = Game.EntityType;
    var stored_entity: ?Entity = null;
    var box_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored_entity = e;
        view.deinit();
    }
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        if (view.next()) |e| box_entity = e;
        view.deinit();
    }

    try testing.expect(stored_entity != null);
    try testing.expect(box_entity != null);

    const stored_in = game.ecs_backend.getComponent(stored_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(box_entity.?)), stored_in.container_id);
}

test "@ref: multiple entity refs in one component" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "ref": "a", "components": { "Health": { "current": 1, "max": 1 } } },
        \\    { "ref": "b", "components": { "Health": { "current": 2, "max": 2 } } },
        \\    { "ref": "link", "components": { "Link": { "source": "@a", "target": "@b" } } }
        \\  ]
        \\}
    );

    const Entity = Game.EntityType;
    var link_entity: ?Entity = null;
    var a_entity: ?Entity = null;
    var b_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Link}, .{});
        if (view.next()) |e| link_entity = e;
        view.deinit();
    }
    // Find a and b by health values
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 1) a_entity = e;
            if (h.current == 2) b_entity = e;
        }
        view.deinit();
    }

    try testing.expect(link_entity != null);
    try testing.expect(a_entity != null);
    try testing.expect(b_entity != null);

    const link = game.ecs_backend.getComponent(link_entity.?, Link).?;
    try testing.expectEqual(@as(u64, @intCast(a_entity.?)), link.source);
    try testing.expectEqual(@as(u64, @intCast(b_entity.?)), link.target);
}

test "@ref: entities without refs work unchanged" {
    // Existing scenes without "ref" should work identically
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "components": { "Health": { "current": 42, "max": 100 } } },
        \\    { "components": { "Health": { "current": 99, "max": 200 } } }
        \\  ]
        \\}
    );

    var count: usize = 0;
    var view = game.ecs_backend.view(.{Health}, .{});
    while (view.next()) |_| count += 1;
    view.deinit();

    try testing.expectEqual(@as(usize, 2), count);
}

test "@ref: mixed refs and non-refs in same scene" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "components": { "Health": { "current": 10, "max": 10 } } },
        \\    { "ref": "box", "components": { "Health": { "current": 20, "max": 20 } } },
        \\    { "components": { "StoredIn": { "container_id": "@box" } } }
        \\  ]
        \\}
    );

    const Entity = Game.EntityType;
    var box_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 20) box_entity = e;
        }
        view.deinit();
    }

    var stored_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored_entity = e;
        view.deinit();
    }

    try testing.expect(box_entity != null);
    try testing.expect(stored_entity != null);

    const stored_in = game.ecs_backend.getComponent(stored_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(box_entity.?)), stored_in.container_id);
}

test "@ref: no memory leaks" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "ref": "a", "components": { "HoldsItem": { "item_id": "@b" } } },
        \\    { "ref": "b", "components": { "StoredIn": { "container_id": "@a" } } }
        \\  ]
        \\}
    );
    // GPA leak detection runs on defer game.deinit() — test passes if no leak
}

test "@ref: ref with non-ref components on same entity" {
    // Entity has both a ref'd component and a regular component
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "ref": "target", "components": { "Health": { "current": 77, "max": 77 } } },
        \\    { "components": { "Health": { "current": 33, "max": 33 }, "StoredIn": { "container_id": "@target" } } }
        \\  ]
        \\}
    );

    const Entity = Game.EntityType;
    var ref_entity: ?Entity = null;
    var stored_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored_entity = e;
        view.deinit();
    }
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 77) ref_entity = e;
        }
        view.deinit();
    }

    try testing.expect(stored_entity != null);
    try testing.expect(ref_entity != null);

    // StoredIn should reference the target
    const stored_in = game.ecs_backend.getComponent(stored_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(ref_entity.?)), stored_in.container_id);

    // The entity with StoredIn should also have its own Health
    const health = game.ecs_backend.getComponent(stored_entity.?, Health).?;
    try testing.expectEqual(@as(f32, 33), health.current);
}
