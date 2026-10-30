//! Save LOADER compatibility regression (#922).
//!
//! `deserializeGameState` is instantiated once per game, over every
//! registered component. #922 moved its per-component work (registry
//! restore, ref arrays, postLoad, post-load markers, post-load create) and
//! the built-in restores (Parent, PrefabInstance, PrefabChild, Tilemap,
//! Camera) into bounded helper functions so LLVM no longer builds one
//! ~133 KB function for a large registry. The split must not change
//! what an existing save loads into, so this file pins:
//!
//!   - `existing_save`: a hand-written v2 save exercising every channel the
//!     loader reads, including malformed entries it must skip, loads into a
//!     world whose re-serialization is byte-identical to `expected_world`.
//!     `expected_world` was captured with the loader BEFORE the split
//!     (engine @ 7ea1d13, #921's branch).
//!   - postLoad hooks, post_load_add markers and post_load_create entities
//!     run exactly as before (observable in `expected_world` and asserted
//!     directly).
//!   - save -> load -> save is a fixed point, and nothing leaks
//!     (`testing.allocator`; the per-component temporary lists are freed by
//!     `defer`s that moved into the helpers).
//!
//! An allocation-failure sweep like the serializer's is not possible here:
//! the load resets the ECS, and the mock ECS panics on OOM by design.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Saveable = core.Saveable;

// ── Fixture components ──────────────────────────────────────────────────

/// Saveable marker that `post_load_add` attaches (visible in re-saves).
const Recalc = struct {
    pub const save = Saveable(.marker, @This(), .{});
};

/// Transient marker that `post_load_add` attaches (never saved).
const Dirty = struct {
    pub const save = Saveable(.transient, @This(), .{});
    _pad: u8 = 0,
};

/// `post_load_create` singleton.
const Rebuild = struct {
    pub const save = Saveable(.marker, @This(), .{ .post_load_create = true });
};

const Worker = struct {
    pub const save = Saveable(.marker, @This(), .{ .post_load_add = &.{ Recalc, Dirty } });
    _pad: u8 = 0,
};

const Stats = struct {
    pub const save = Saveable(.saveable, @This(), .{ .entity_refs = &.{ "target", "home" } });
    hp: f32 = 100,
    level: u16 = 1,
    target: u64 = 0,
    home: ?u64 = null,
    mood: enum { calm, angry } = .calm,
};

const Container = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{ "children", "slot_count" },
        .ref_arrays = &.{"children"},
    });
    capacity: u32 = 0,
    children: []const u64 = &.{},
    slot_count: u32 = 0,

    /// Derived state rebuilt after load (slot_count is never saved).
    pub fn postLoad(self: *Container, game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        self.slot_count = @intCast(self.children.len * 10);
    }
};

const Squad = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{"members"},
        .ref_arrays = &.{"members"},
    });
    members: []const u64 = &.{},
};

const TestComponents = engine.ComponentRegistry(.{
    .Recalc = Recalc,
    .Dirty = Dirty,
    .Rebuild = Rebuild,
    .Worker = Worker,
    .Stats = Stats,
    .Container = Container,
    .Squad = Squad,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

/// An "existing" v2 save. Saved ids are deliberately sparse and out of
/// order so every entity ref has to be remapped. It also carries input
/// the loader must skip without failing the load:
///   - an unknown component name (`Gone`)
///   - a non-object `Parent`, a negative `PrefabChild.root`
///   - a `Tilemap` binding that isn't an object, a `Camera` without zoom
///   - an entity without an `id`, and one whose `components` isn't an object
const existing_save =
    \\{
    \\  "version": 2,
    \\  "entities": [
    \\    {
    \\      "id": 10,
    \\      "components": {
    \\        "Position": {"x": 1.5, "y": -2},
    \\        "Worker": {"_pad": 0},
    \\        "Stats": {"hp": 42.5, "level": 3, "target": 20, "home": 30, "mood": "angry"},
    \\        "Squad": {},
    \\        "Gone": {"x": 1}
    \\      },
    \\      "ref_arrays": {"members": [10, 20, 30, 99]}
    \\    },
    \\    {
    \\      "id": 20,
    \\      "components": {
    \\        "Position": {"x": 100, "y": 200},
    \\        "Container": {"capacity": 8},
    \\        "PrefabInstance": {"path": "rooms/kitchen", "overrides": "{}"},
    \\        "Parent": 123
    \\      },
    \\      "ref_arrays": {"children": [30, 10]}
    \\    },
    \\    {
    \\      "id": 30,
    \\      "components": {
    \\        "Position": {"x": 3, "y": 4},
    \\        "Worker": {},
    \\        "Parent": {"entity": 10, "inherit_rotation": false, "inherit_scale": true},
    \\        "PrefabChild": {"root": -1, "local_path": "children[0]"}
    \\      }
    \\    },
    \\    {
    \\      "id": 40,
    \\      "components": {
    \\        "Tilemap": {"asset_name": "maps/a", "layer_bindings": [7, {"tmx_layer": "g", "engine_layer": "bg"}]},
    \\        "Camera": {"viewport": {"x": 1, "y": 2, "width": 30, "height": 40}, "tag": "mini"}
    \\      }
    \\    },
    \\    {
    \\      "components": {"Worker": {}}
    \\    },
    \\    {
    \\      "id": 50,
    \\      "components": 5
    \\    }
    \\  ]
    \\}
;

/// Re-serialization of the world `existing_save` loads into, captured with
/// the pre-#922 loader.
const expected_world =
    \\{
    \\  "version": 2,
    \\  "entities": [
    \\    {
    \\      "id": 1,
    \\      "components": {
    \\        "Position": {"x": 1.5, "y": -2},
    \\        "Recalc": {},
    \\        "Worker": {"_pad": 0},
    \\        "Stats": {"hp": 42.500000,"level": 3,"target": 2,"home": 3,"mood": "angry"},
    \\        "Squad": {}
    \\      },
    \\      "ref_arrays": {"members": [1,2,3,99]}
    \\    },
    \\    {
    \\      "id": 3,
    \\      "components": {
    \\        "Position": {"x": 3, "y": 4},
    \\        "Parent": {"entity": 1, "inherit_rotation": false, "inherit_scale": true},
    \\        "Recalc": {},
    \\        "Worker": {"_pad": 0}
    \\      }
    \\    },
    \\    {
    \\      "id": 6,
    \\      "components": {
    \\        "Position": {"x": 0, "y": 0},
    \\        "Rebuild": {}
    \\      }
    \\    },
    \\    {
    \\      "id": 2,
    \\      "components": {
    \\        "Position": {"x": 100, "y": 200},
    \\        "PrefabInstance": {"path": "rooms/kitchen", "overrides": "{}"},
    \\        "Container": {"capacity": 8}
    \\      },
    \\      "ref_arrays": {"children": [3,1]}
    \\    },
    \\    {
    \\      "id": 4,
    \\      "components": {
    \\        "Position": {"x": 0, "y": 0},
    \\        "Tilemap": {"asset_name": "maps/a", "layer_bindings": [{"tmx_layer": "g", "engine_layer": "bg"}]},
    \\        "Camera": {"zoom": 1, "viewport": {"x": 1, "y": 2, "width": 30, "height": 40}, "tag": "mini"}
    \\      }
    \\    }
    \\  ]
    \\}
++ "\n";

fn findOne(game: *TestGame, comptime T: type) !TestGame.EntityType {
    var view = game.active_world.ecs_backend.view(.{T}, .{});
    defer view.deinit();
    const found = view.next() orelse return error.TestExpectedEntity;
    try testing.expect(view.next() == null);
    return found;
}

fn countWith(game: *TestGame, comptime T: type) usize {
    var view = game.active_world.ecs_backend.view(.{T}, .{});
    defer view.deinit();
    var n: usize = 0;
    while (view.next()) |_| n += 1;
    return n;
}

test "save loader: an existing save loads into the same world as before #922" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.deserializeGameState(existing_save);

    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected_world, bytes);
}

test "save loader: postLoad, post-load markers and post-load create run" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.deserializeGameState(existing_save);
    const ecs = &game.active_world.ecs_backend;

    // postLoad rebuilt the never-saved derived field from the restored
    // (remapped) ref array.
    const house = try findOne(&game, Container);
    const container = ecs.getComponent(house, Container).?;
    try testing.expectEqual(@as(usize, 2), container.children.len);
    try testing.expectEqual(@as(u32, 20), container.slot_count);

    // Both workers (the one without an id was never created) got both
    // markers, the transient one included.
    try testing.expectEqual(@as(usize, 2), countWith(&game, Worker));
    try testing.expectEqual(@as(usize, 2), countWith(&game, Recalc));
    try testing.expectEqual(@as(usize, 2), countWith(&game, Dirty));

    // Exactly one post_load_create singleton.
    _ = try findOne(&game, Rebuild);

    // Entity refs remapped; a ref-array id with no saved entity (99) is
    // kept as-is, exactly as before.
    var view = ecs.view(.{ Worker, Squad }, .{});
    defer view.deinit();
    const worker = view.next().?;
    const stats = ecs.getComponent(worker, Stats).?;
    try testing.expectEqual(@as(u64, @intCast(house)), stats.target);
    const members = ecs.getComponent(worker, Squad).?.members;
    try testing.expectEqual(@as(usize, 4), members.len);
    try testing.expectEqual(@as(u64, @intCast(worker)), members[0]);
    try testing.expectEqual(@as(u64, 99), members[3]);

    // The second worker never had `Stats`; its malformed built-ins were
    // skipped without failing the load.
    const pet = try findOne(&game, TestGame.ParentComp);
    try testing.expect(ecs.getComponent(pet, Stats) == null);
    try testing.expect(ecs.getComponent(pet, TestGame.PrefabChildComp) == null);
}

test "save loader: save -> load -> save is a fixed point" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try game.deserializeGameState(existing_save);
    const first = try game.serializeGameState();
    defer testing.allocator.free(first);

    var again = TestGame.init(testing.allocator);
    defer again.deinit();
    try again.deserializeGameState(first);
    const second = try again.serializeGameState();
    defer testing.allocator.free(second);

    // post_load_create adds one more singleton per load; everything else
    // must round-trip unchanged.
    try testing.expectEqual(@as(usize, 2), countWith(&again, Rebuild));
    try testing.expect(std.mem.indexOf(u8, second, "\"Rebuild\": {}") != null);
    var view = again.active_world.ecs_backend.view(.{Container}, .{});
    defer view.deinit();
    const house = view.next().?;
    try testing.expectEqual(@as(u32, 20), again.active_world.ecs_backend.getComponent(house, Container).?.slot_count);
}
