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

/// Simulates a Workstation with nested storage entities ([]const u64).
const Container = struct {
    slots: []const u64 = &.{},
};

const Components = engine.ComponentRegistry(.{
    .StoredIn = StoredIn,
    .HoldsItem = HoldsItem,
    .Health = Health,
    .Link = Link,
    .Container = Container,
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

test "@ref: refs inside prefab with children" {
    // Prefab defines a parent + child that reference each other via @ref.
    // This tests that refs work within prefab children, not just top-level entities.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    // Prefab: container with a stored item as a child
    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/box_with_item.jsonc",
        .data =
        \\{
        \\  "ref": "box",
        \\  "components": {
        \\    "Health": { "current": 99, "max": 99 },
        \\    "HoldsItem": { "item_id": "@item" }
        \\  },
        \\  "children": [
        \\    {
        \\      "ref": "item",
        \\      "components": {
        \\        "Health": { "current": 11, "max": 11 },
        \\        "StoredIn": { "container_id": "@box" }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    { "prefab": "box_with_item", "components": { "Position": { "x": 10, "y": 20 } } }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);

    const Entity = Game.EntityType;
    var box_entity: ?Entity = null;
    var item_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 99) box_entity = e;
            if (h.current == 11) item_entity = e;
        }
        view.deinit();
    }

    try testing.expect(box_entity != null);
    try testing.expect(item_entity != null);

    // Box's HoldsItem should reference the item
    const holds = game.ecs_backend.getComponent(box_entity.?, HoldsItem).?;
    try testing.expectEqual(@as(u64, @intCast(item_entity.?)), holds.item_id);

    // Item's StoredIn should reference the box
    const stored = game.ecs_backend.getComponent(item_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(box_entity.?)), stored.container_id);
}

test "@ref: cross-reference between prefab and scene entity" {
    // A scene entity references a prefab-spawned entity via @ref.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/container.jsonc",
        .data =
        \\{
        \\  "components": {
        \\    "Health": { "current": 88, "max": 88 }
        \\  }
        \\}
        ,
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    { "ref": "mybox", "prefab": "container", "components": { "Position": { "x": 0, "y": 0 } } },
        \\    { "components": { "StoredIn": { "container_id": "@mybox" } } }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);

    const Entity = Game.EntityType;
    var box_entity: ?Entity = null;
    var stored_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        if (view.next()) |e| box_entity = e;
        view.deinit();
    }
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored_entity = e;
        view.deinit();
    }

    try testing.expect(box_entity != null);
    try testing.expect(stored_entity != null);

    const stored = game.ecs_backend.getComponent(stored_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(box_entity.?)), stored.container_id);
}

test "@ref: position offset applied correctly with refs" {
    // Parent at (100, 200), child at relative (10, 20).
    // Child should end up at absolute (110, 220).
    // Refs should resolve correctly alongside position offsetting.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/parent_with_child.jsonc",
        .data =
        \\{
        \\  "ref": "parent",
        \\  "components": {
        \\    "Health": { "current": 50, "max": 50 },
        \\    "HoldsItem": { "item_id": "@child" }
        \\  },
        \\  "children": [
        \\    {
        \\      "ref": "child",
        \\      "components": {
        \\        "Position": { "x": 10, "y": 20 },
        \\        "Health": { "current": 25, "max": 25 },
        \\        "StoredIn": { "container_id": "@parent" }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    { "prefab": "parent_with_child", "components": { "Position": { "x": 100, "y": 200 } } }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);

    const Entity = Game.EntityType;
    const Position = @import("labelle-core").Position;
    var parent_entity: ?Entity = null;
    var child_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 50) parent_entity = e;
            if (h.current == 25) child_entity = e;
        }
        view.deinit();
    }

    try testing.expect(parent_entity != null);
    try testing.expect(child_entity != null);

    // Parent position: (100, 200)
    const parent_pos: Position = game.getPosition(parent_entity.?);
    try testing.expectEqual(@as(f32, 100), parent_pos.x);
    try testing.expectEqual(@as(f32, 200), parent_pos.y);

    // Child position: parent (100, 200) + local (10, 20) = (110, 220)
    const child_pos: Position = game.getPosition(child_entity.?);
    try testing.expectEqual(@as(f32, 110), child_pos.x);
    try testing.expectEqual(@as(f32, 220), child_pos.y);

    // Refs should still resolve correctly
    const holds = game.ecs_backend.getComponent(parent_entity.?, HoldsItem).?;
    try testing.expectEqual(@as(u64, @intCast(child_entity.?)), holds.item_id);

    const stored = game.ecs_backend.getComponent(child_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(parent_entity.?)), stored.container_id);
}

test "@ref: nested entity arrays register refs (#415)" {
    // A container with nested entity-like items in its "slots" array.
    // The nested entities should be visible via @ref from top-level entities.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            { "ref": "slot_a", "components": { "Health": { "current": 10, "max": 10 } } },
        \\            { "ref": "slot_b", "components": { "Health": { "current": 20, "max": 20 } } }
        \\          ]
        \\        }
        \\      }
        \\    },
        \\    { "components": { "StoredIn": { "container_id": "@slot_a" } } }
        \\  ]
        \\}
    );

    const Entity = Game.EntityType;

    // Find slot_a by health value
    var slot_a: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 10) slot_a = e;
        }
        view.deinit();
    }

    // Find the entity that references slot_a
    var stored_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{StoredIn}, .{});
        if (view.next()) |e| stored_entity = e;
        view.deinit();
    }

    try testing.expect(slot_a != null);
    try testing.expect(stored_entity != null);

    const stored_in = game.ecs_backend.getComponent(stored_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(slot_a.?)), stored_in.container_id);
}

test "@ref: nested entities with children and cross-refs (#415)" {
    // Nested entity (in slots array) uses a prefab with children.
    // The prefab's children use @ref to reference each other.
    // Simulates eis_with_water inside a workstation's storages array.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    // Prefab: storage with a child item, cross-referenced
    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/filled_slot.jsonc",
        .data =
        \\{
        \\  "ref": "storage",
        \\  "components": {
        \\    "Health": { "current": 50, "max": 50 },
        \\    "HoldsItem": { "item_id": "@item" }
        \\  },
        \\  "children": [
        \\    {
        \\      "ref": "item",
        \\      "components": {
        \\        "Health": { "current": 5, "max": 5 },
        \\        "StoredIn": { "container_id": "@storage" }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            { "prefab": "filled_slot", "components": { "Position": { "x": 10, "y": 0 } } },
        \\            { "components": { "Health": { "current": 1, "max": 1 } } }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);

    const Entity = Game.EntityType;

    // Find storage (health=50), item (health=5), empty slot (health=1)
    var storage_entity: ?Entity = null;
    var item_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 50) storage_entity = e;
            if (h.current == 5) item_entity = e;
        }
        view.deinit();
    }

    try testing.expect(storage_entity != null);
    try testing.expect(item_entity != null);

    // Storage's HoldsItem should reference the item
    const holds = game.ecs_backend.getComponent(storage_entity.?, HoldsItem).?;
    try testing.expectEqual(@as(u64, @intCast(item_entity.?)), holds.item_id);

    // Item's StoredIn should reference the storage
    const stored = game.ecs_backend.getComponent(item_entity.?, StoredIn).?;
    try testing.expectEqual(@as(u64, @intCast(storage_entity.?)), stored.container_id);

    // Container should have 2 slots
    var container_entity: ?Entity = null;
    {
        var view = game.ecs_backend.view(.{Container}, .{});
        if (view.next()) |e| container_entity = e;
        view.deinit();
    }
    try testing.expect(container_entity != null);
    const container = game.ecs_backend.getComponent(container_entity.?, Container).?;
    try testing.expectEqual(@as(usize, 2), container.slots.len);
}
