//! Save serializer byte-for-byte regression (#921).
//!
//! `serializeGameState` is instantiated once per game, over every
//! registered component. #921 split its per-component work into bounded
//! helper functions so LLVM no longer builds one ~0.5 MB WASM function
//! for a large registry. That split must not change a single byte of the
//! save format, so this file pins the exact output of the serializer on a
//! fixture world that exercises every channel it writes:
//!
//!   - registry components: plain saveable (floats/ints/bools/enums/
//!     optionals/nested structs/EnumSet), marker with a pad byte, marker
//!     with no fields, transient (must be absent), unregistered (absent)
//!   - entity refs (written raw, remapped on load)
//!   - ref arrays from two different components on one entity (the
//!     `ref_arrays` object's inter-component comma) plus an empty array
//!   - built-ins: Position (not registered here), Parent, PrefabInstance,
//!     PrefabChild, Tilemap (with layer bindings), Camera (with viewport
//!     and tag), and the scene name — including JSON string escaping
//!
//! `golden_save` below was captured from the serializer BEFORE the split
//! (engine main @ fe662e9) and is also loaded back as an "existing save"
//! to prove saves written by the old serializer still load.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Position = core.Position;
const Saveable = core.Saveable;

// ── Fixture components ──────────────────────────────────────────────────

const Mood = enum { calm, angry, asleep };
const Trait = enum { brave, lazy, smart };

const Worker = struct {
    pub const save = Saveable(.marker, @This(), .{});
    _pad: u8 = 0,
};

/// Field-less marker — serialises as `{}`.
const Selected = struct {
    pub const save = Saveable(.marker, @This(), .{});
};

const Stats = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .entity_refs = &.{ "target", "home" },
    });
    hp: f32 = 100,
    level: u16 = 1,
    debt: i32 = 0,
    alive: bool = true,
    mood: Mood = .calm,
    target: u64 = 0,
    home: ?u64 = null,
    bonus: ?f32 = null,
    offset: struct { dx: i8 = 0, dy: i8 = 0 } = .{},
    traits: std.EnumSet(Trait) = .initEmpty(),
};

const Container = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{ "children", "reserved", "slot_count" },
        .ref_arrays = &.{ "children", "reserved" },
    });
    capacity: u32 = 0,
    children: []const u64 = &.{},
    reserved: []const u64 = &.{},
    slot_count: u32 = 0,
};

const Squad = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{"members"},
        .ref_arrays = &.{"members"},
    });
    members: []const u64 = &.{},
    formation: enum { line, wedge } = .line,
};

const Scratch = struct {
    pub const save = Saveable(.transient, @This(), .{
        .skip = &.{"cache"},
        .ref_arrays = &.{"cache"},
    });
    cache: []const u64 = &.{},
};

/// Not registered — a render-only component the save must ignore.
const Visual = struct {
    z: i16 = 0,
};

const TestComponents = engine.ComponentRegistry(.{
    .Worker = Worker,
    .Selected = Selected,
    .Stats = Stats,
    .Container = Container,
    .Squad = Squad,
    .Scratch = Scratch,
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

const Fixture = struct {
    worker: TestGame.EntityType,
    house: TestGame.EntityType,
    pet: TestGame.EntityType,
    map: TestGame.EntityType,
    cam: TestGame.EntityType,
};

const children_ids = [_]u64{ 1, 3 };
const squad_ids = [_]u64{ 1, 2, 3 };
const scratch_ids = [_]u64{ 9, 9 };
const bindings = [_]engine.TilemapLayerBinding{
    .{ .tmx_layer = "ground", .engine_layer = "background" },
    .{ .tmx_layer = "deco\"1\"", .engine_layer = "world" },
};

fn buildFixture(game: *TestGame) !Fixture {
    const ecs = &game.active_world.ecs_backend;

    const worker = game.createEntity();
    game.setPosition(worker, .{ .x = 10.5, .y = -20.25 });
    ecs.addComponent(worker, Worker{});
    ecs.addComponent(worker, Selected{});
    ecs.addComponent(worker, Stats{
        .hp = 75.125,
        .level = 7,
        .debt = -42,
        .alive = true,
        .mood = .angry,
        .home = null,
        .bonus = 1.5,
        .offset = .{ .dx = -3, .dy = 4 },
        .traits = .initMany(&.{ .brave, .smart }),
    });
    ecs.addComponent(worker, Squad{ .members = &squad_ids, .formation = .wedge });
    ecs.addComponent(worker, Scratch{ .cache = &scratch_ids });
    ecs.addComponent(worker, Visual{ .z = 5 });

    const house = game.createEntity();
    game.setPosition(house, .{ .x = 100, .y = 200 });
    ecs.addComponent(house, Container{
        .capacity = 4,
        .children = &children_ids,
        .reserved = &.{},
        .slot_count = 2,
    });
    ecs.addComponent(house, TestGame.PrefabInstanceComp{
        .path = "buildings/house",
        .overrides = "{\"tint\":\"red\\\\blue\"}\n\t\x01",
    });

    // Worker's target / home point at the house (raw ids, remapped on load).
    ecs.getComponent(worker, Stats).?.target = @intCast(house);
    ecs.getComponent(worker, Stats).?.home = @intCast(house);

    const pet = game.createEntity();
    game.setPosition(pet, .{ .x = 1, .y = 2 });
    game.setParent(pet, worker, .{ .inherit_rotation = true });
    ecs.addComponent(pet, TestGame.PrefabChildComp{ .root = house, .local_path = "children[0]" });
    ecs.addComponent(pet, Stats{ .mood = .asleep, .target = @intCast(worker) });

    const map = game.createEntity();
    ecs.addComponent(map, TestGame.TilemapComp{ .asset_name = "maps/level_1", .layer_bindings = &bindings });

    const cam = game.createEntity();
    game.setPosition(cam, .{ .x = 320, .y = 240 });
    var camera: TestGame.CameraComp = .{ .zoom = 2.5, .viewport = .{ .x = 0, .y = 10, .width = 640, .height = 360 } };
    camera.setTagSlice("mini\\map");
    ecs.addComponent(cam, camera);

    // Entity with only unregistered/transient state — never saved.
    const ghost = game.createEntity();
    ecs.addComponent(ghost, Visual{});
    ecs.addComponent(ghost, Scratch{});

    game.active_world.setLoadedSaveSceneName(try game.allocator.dupe(u8, "level \"1\""));

    return .{ .worker = worker, .house = house, .pet = pet, .map = map, .cam = cam };
}

/// Captured from `serializeGameState` before the #921 split.
const golden_save =
    \\{
    \\  "version": 2,
    \\  "scene": "level \"1\"",
    \\  "entities": [
    \\    {
    \\      "id": 1,
    \\      "components": {
    \\        "Position": {"x": 10.5, "y": -20.25},
    \\        "Worker": {"_pad": 0},
    \\        "Selected": {},
    \\        "Stats": {"hp": 75.125000,"level": 7,"debt": -42,"alive": true,"mood": "angry","target": 2,"home": 2,"bonus": 1.500000,"offset": {"dx": -3,"dy": 4},"traits": {"bits": {"mask": 5}}},
    \\        "Squad": {"formation": "wedge"}
    \\      },
    \\      "ref_arrays": {"members": [1,2,3]}
    \\    },
    \\    {
    \\      "id": 3,
    \\      "components": {
    \\        "Position": {"x": 1, "y": 2},
    \\        "Parent": {"entity": 1, "inherit_rotation": true, "inherit_scale": false},
    \\        "PrefabChild": {"root": 2, "local_path": "children[0]"},
    \\        "Stats": {"hp": 100.000000,"level": 1,"debt": 0,"alive": true,"mood": "asleep","target": 1,"home": null,"bonus": null,"offset": {"dx": 0,"dy": 0},"traits": {"bits": {"mask": 0}}}
    \\      }
    \\    },
    \\    {
    \\      "id": 2,
    \\      "components": {
    \\        "Position": {"x": 100, "y": 200},
    \\        "PrefabInstance": {"path": "buildings/house", "overrides": "{\"tint\":\"red\\\\blue\"}\n\t\u0001"},
    \\        "Container": {"capacity": 4}
    \\      },
    \\      "ref_arrays": {"children": [1,3],"reserved": []}
    \\    },
    \\    {
    \\      "id": 4,
    \\      "components": {
    \\        "Position": {"x": 0, "y": 0},
    \\        "Tilemap": {"asset_name": "maps/level_1", "layer_bindings": [{"tmx_layer": "ground", "engine_layer": "background"}, {"tmx_layer": "deco\"1\"", "engine_layer": "world"}]}
    \\      }
    \\    },
    \\    {
    \\      "id": 5,
    \\      "components": {
    \\        "Position": {"x": 320, "y": 240},
    \\        "Camera": {"zoom": 2.5, "viewport": {"x": 0, "y": 10, "width": 640, "height": 360}, "tag": "mini\\map"}
    \\      }
    \\    }
    \\  ]
    \\}
++ "\n";

test "save serializer: output is byte-identical to the pre-#921 serializer" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    _ = try buildFixture(&game);

    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(golden_save, bytes);
}

fn findOne(game: *TestGame, comptime T: type) !TestGame.EntityType {
    var view = game.active_world.ecs_backend.view(.{T}, .{});
    defer view.deinit();
    const found = view.next() orelse return error.TestExpectedEntity;
    try testing.expect(view.next() == null);
    return found;
}

test "save serializer: a save written by the pre-#921 serializer still loads" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.deserializeGameState(golden_save);

    const ecs = &game.active_world.ecs_backend;

    // Worker: marker components, every scalar kind, entity refs remapped,
    // ref array restored and remapped.
    const worker = try findOne(&game, Worker);
    try testing.expect(ecs.hasComponent(worker, Selected));
    const pos = game.getPosition(worker);
    try testing.expectEqual(@as(f32, 10.5), pos.x);
    try testing.expectEqual(@as(f32, -20.25), pos.y);
    const stats = ecs.getComponent(worker, Stats).?;
    try testing.expectEqual(@as(f32, 75.125), stats.hp);
    try testing.expectEqual(@as(u16, 7), stats.level);
    try testing.expectEqual(@as(i32, -42), stats.debt);
    try testing.expectEqual(Mood.angry, stats.mood);
    try testing.expectEqual(@as(?f32, 1.5), stats.bonus);
    try testing.expectEqual(@as(i8, -3), stats.offset.dx);
    try testing.expectEqual(@as(i8, 4), stats.offset.dy);
    try testing.expect(stats.traits.contains(.brave));
    try testing.expect(!stats.traits.contains(.lazy));
    try testing.expect(stats.traits.contains(.smart));
    const squad = ecs.getComponent(worker, Squad).?;
    try testing.expectEqual(.wedge, squad.formation);
    try testing.expectEqual(@as(usize, 3), squad.members.len);
    try testing.expectEqual(@as(u64, @intCast(worker)), squad.members[0]);

    // House: ref arrays (incl. an empty one) remapped to the new ids.
    const house = try findOne(&game, Container);
    try testing.expectEqual(@as(u64, @intCast(house)), stats.target);
    try testing.expectEqual(@as(?u64, @intCast(house)), stats.home);
    const container = ecs.getComponent(house, Container).?;
    try testing.expectEqual(@as(u32, 4), container.capacity);
    try testing.expectEqual(@as(usize, 2), container.children.len);
    try testing.expectEqual(@as(u64, @intCast(worker)), container.children[0]);
    try testing.expectEqual(@as(usize, 0), container.reserved.len);
    try testing.expectEqual(@as(f32, 200), game.getPosition(house).y);

    // Pet: built-in Parent remapped onto the restored worker.
    const pet = try findOne(&game, TestGame.ParentComp);
    const parent = ecs.getComponent(pet, TestGame.ParentComp).?;
    try testing.expectEqual(worker, parent.entity);
    try testing.expect(parent.inherit_rotation);
    try testing.expect(!parent.inherit_scale);
    try testing.expectEqual(Mood.asleep, ecs.getComponent(pet, Stats).?.mood);
    try testing.expectEqual(@as(u64, @intCast(worker)), ecs.getComponent(pet, Stats).?.target);

    // Built-in Tilemap (with its explicit layer bindings) and Camera.
    const map = try findOne(&game, TestGame.TilemapComp);
    const tm = ecs.getComponent(map, TestGame.TilemapComp).?;
    try testing.expectEqualStrings("maps/level_1", tm.asset_name);
    try testing.expectEqual(@as(usize, 2), tm.layer_bindings.?.len);
    try testing.expectEqualStrings("deco\"1\"", tm.layer_bindings.?[1].tmx_layer);

    const cam_entity = try findOne(&game, TestGame.CameraComp);
    const cam = ecs.getComponent(cam_entity, TestGame.CameraComp).?;
    try testing.expectEqual(@as(f32, 2.5), cam.zoom);
    try testing.expectEqual(@as(i32, 360), cam.viewport.?.height);
    try testing.expectEqualStrings("mini\\map", cam.tagSlice());
    try testing.expectEqual(@as(f32, 320), game.getPosition(cam_entity).x);

    // Transient and unregistered state was never written, so never restored.
    var scratch = ecs.view(.{Scratch}, .{});
    defer scratch.deinit();
    try testing.expect(scratch.next() == null);
}

test "save serializer: every allocation failure propagates and leaks nothing" {
    // The split moved the per-component entity collection (and its
    // temporary list) into helper functions. Fail each serializer
    // allocation in turn: every one must surface as error.OutOfMemory
    // with all temporaries freed (testing.allocator reports leaks), and
    // the first non-failing run must still produce the golden bytes.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    _ = try buildFixture(&game);

    // Only the serializer's own allocations go through `game.allocator`
    // here — the mock ECS captured the real allocator at init, and its
    // `view` panics on OOM by design.
    const real_allocator = game.allocator;
    defer game.allocator = real_allocator;

    var saw_oom = false;
    var saw_write_failed = false;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(real_allocator, .{ .fail_index = fail_index });
        game.allocator = failing.allocator();
        const result = game.serializeGameState();
        game.allocator = real_allocator;
        if (result) |bytes| {
            defer real_allocator.free(bytes);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqualStrings(golden_save, bytes);
            break;
        } else |err| {
            // Allocation failures inside `std.Io.Writer.Allocating`
            // surface as `error.WriteFailed` (the writer interface's
            // error set); everything else as `error.OutOfMemory`.
            if (err != error.OutOfMemory and err != error.WriteFailed) return err;
            try testing.expect(failing.has_induced_failure);
            if (err == error.OutOfMemory) saw_oom = true;
            if (err == error.WriteFailed) saw_write_failed = true;
        }
    }
    // The fixture world allocates in collection, the dedup set, the
    // entity list and the output buffer — make sure we actually swept.
    try testing.expect(fail_index > 4);
    try testing.expect(saw_oom);
    try testing.expect(saw_write_failed);
}

test "save serializer: empty world output is unchanged" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\n  \"version\": 2,\n  \"entities\": [\n\n  ]\n}\n", bytes);
}
