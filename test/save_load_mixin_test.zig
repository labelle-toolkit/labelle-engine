/// Integration test for save/load mixin.
///
/// Creates a Game with saveable components, populates entities,
/// saves to file, destroys all state, loads from file, and verifies
/// the full round-trip including entity ID remapping, postLoad hooks,
/// post_load_add markers, and post_load_create entities.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Position = core.Position;
const Saveable = core.Saveable;

const game_mod = engine.game_mod;
const scene_mod = engine.scene_mod;
const ComponentRegistry = scene_mod.ComponentRegistry;

// ── Test Components ─────────────────────────────────────────────────────

const NeedsRecalc = struct {
    pub const save = Saveable(.transient, @This(), .{});
    _marker: u8 = 0,
};

const RebuildMarker = struct {
    pub const save = Saveable(.transient, @This(), .{
        .post_load_create = true,
    });
    _marker: u8 = 0,
};

const Worker = struct {
    pub const save = Saveable(.marker, @This(), .{
        .post_load_add = &.{NeedsRecalc},
    });
    _pad: u8 = 0,
};

const Health = struct {
    pub const save = Saveable(.saveable, @This(), .{});
    current: f32 = 100,
    max: f32 = 100,
};

const Storage = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .entity_refs = &.{"owner"},
    });
    owner: u64 = 0,
    capacity: u32 = 10,
};

/// Transient component with ref arrays — should NOT be saved.
const TransientRefs = struct {
    pub const save = Saveable(.transient, @This(), .{
        .skip = &.{"targets"},
        .ref_arrays = &.{"targets"},
    });
    targets: []const u64 = &.{},
};

const Container = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{"children"},
        .ref_arrays = &.{"children"},
    });
    name: u32 = 0,
    children: []const u64 = &.{},
    slot_count: u32 = 0,

    pub fn postLoad(self: *Container, game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        // Simulate rebuilding derived state from children
        self.slot_count = @intCast(self.children.len);
    }
};

const TestComponents = ComponentRegistry(.{
    .Position = Position,
    .Worker = Worker,
    .Health = Health,
    .Storage = Storage,
    .Container = Container,
    .NeedsRecalc = NeedsRecalc,
    .RebuildMarker = RebuildMarker,
    .TransientRefs = TransientRefs,
});

// ── Test Game Type ──────────────────────────────────────────────────────

const MockEcs = core.MockEcsBackend(u32);
const TestGame = game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    @import("engine").input_mod.StubInput,
    @import("engine").audio_mod.StubAudio,
    @import("engine").gui_mod.StubGui,
    void, // no hooks
    core.StubLogSink,
    TestComponents,
    &.{}, // no gizmo categories
    void, // no game events
);

// ── Tests ───────────────────────────────────────────────────────────────

test "save/load mixin: full round-trip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Create entities
    const worker_entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(worker_entity, Position{ .x = 10.0, .y = 20.0 });
    game.active_world.ecs_backend.addComponent(worker_entity, Worker{});
    game.active_world.ecs_backend.addComponent(worker_entity, Health{ .current = 75.0, .max = 100.0 });

    const storage_entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(storage_entity, Position{ .x = 50.0, .y = 60.0 });
    game.active_world.ecs_backend.addComponent(storage_entity, Storage{
        .owner = @intCast(worker_entity),
        .capacity = 20,
    });

    const container_entity = game.createEntity();
    const children_slice = try testing.allocator.alloc(u64, 2);
    defer testing.allocator.free(children_slice);
    children_slice[0] = @intCast(worker_entity);
    children_slice[1] = @intCast(storage_entity);
    game.active_world.ecs_backend.addComponent(container_entity, Position{ .x = 100.0, .y = 200.0 });
    game.active_world.ecs_backend.addComponent(container_entity, Container{
        .name = 42,
        .children = children_slice,
        .slot_count = 99, // will be overwritten by postLoad
    });

    // Save
    const filename = "test_save.json";
    try game.saveGameState(filename);
    defer std.fs.cwd().deleteFile(filename) catch {};

    // Verify file was created
    const stat = try std.fs.cwd().statFile(filename);
    try testing.expect(stat.size > 0);

    // Destroy all state
    game.resetEcsBackend();

    // Load
    try game.loadGameState(filename);

    // ── Verify restored state ───────────────────────────────────────

    // Worker entity should exist with position, marker, health, and NeedsRecalc (post_load_add)
    var worker_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Worker}, .{});
        while (view.next()) |ent| {
            worker_count += 1;
            // Check position was restored
            const pos = game.active_world.ecs_backend.getComponent(ent, Position).?;
            try testing.expectApproxEqAbs(@as(f32, 10.0), pos.x, 0.01);
            try testing.expectApproxEqAbs(@as(f32, 20.0), pos.y, 0.01);

            // Check health was restored
            const health = game.active_world.ecs_backend.getComponent(ent, Health).?;
            try testing.expectApproxEqAbs(@as(f32, 75.0), health.current, 0.01);
            try testing.expectApproxEqAbs(@as(f32, 100.0), health.max, 0.01);

            // Check NeedsRecalc was added by post_load_add
            try testing.expect(game.active_world.ecs_backend.hasComponent(ent, NeedsRecalc));
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), worker_count);

    // Find the new worker entity ID for remapping assertions
    var new_worker_id: u64 = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Worker}, .{});
        if (view.next()) |ent| new_worker_id = @intCast(ent);
        view.deinit();
    }

    // Storage entity should have remapped owner pointing to new worker
    var storage_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Storage}, .{});
        while (view.next()) |ent| {
            storage_count += 1;
            const stor = game.active_world.ecs_backend.getComponent(ent, Storage).?;
            try testing.expectEqual(@as(u32, 20), stor.capacity);
            try testing.expectEqual(new_worker_id, stor.owner);
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), storage_count);

    // Container should have postLoad called (slot_count = children.len)
    var container_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Container}, .{});
        while (view.next()) |ent| {
            container_count += 1;
            const cont = game.active_world.ecs_backend.getComponent(ent, Container).?;
            try testing.expectEqual(@as(u32, 42), cont.name);
            // postLoad should have set slot_count = children.len = 2
            try testing.expectEqual(@as(u32, 2), cont.slot_count);
            // children ref array should be restored with 2 entries
            try testing.expectEqual(@as(usize, 2), cont.children.len);
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), container_count);

    // RebuildMarker should have been created by post_load_create
    var rebuild_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{RebuildMarker}, .{});
        while (view.next()) |_| {
            rebuild_count += 1;
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rebuild_count);
}

test "save/load mixin: empty world round-trip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const filename = "test_save_empty.json";
    try game.saveGameState(filename);
    defer std.fs.cwd().deleteFile(filename) catch {};

    try game.loadGameState(filename);

    // No entities should exist (except post_load_create)
    var worker_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Worker}, .{});
        while (view.next()) |_| worker_count += 1;
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 0), worker_count);

    // RebuildMarker should still be created
    var rebuild_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{RebuildMarker}, .{});
        while (view.next()) |_| rebuild_count += 1;
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rebuild_count);
}

test "save/load mixin: transient ref arrays are not saved" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Create entity with both saveable and transient ref array components
    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Position{ .x = 1.0, .y = 2.0 });
    game.active_world.ecs_backend.addComponent(entity, Worker{});

    const targets = try testing.allocator.alloc(u64, 2);
    defer testing.allocator.free(targets);
    targets[0] = 10;
    targets[1] = 20;
    game.active_world.ecs_backend.addComponent(entity, TransientRefs{ .targets = targets });

    // Save
    const filename = "test_save_transient.json";
    try game.saveGameState(filename);
    defer std.fs.cwd().deleteFile(filename) catch {};

    // Verify transient ref arrays are NOT in the JSON
    const json = try std.fs.cwd().readFileAlloc(testing.allocator, filename, 1024 * 1024);
    defer testing.allocator.free(json);

    // The JSON should not contain "targets" in ref_arrays
    try testing.expect(std.mem.indexOf(u8, json, "targets") == null);

    // Load and verify entity exists but without TransientRefs
    game.resetEcsBackend();
    try game.loadGameState(filename);

    var worker_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Worker}, .{});
        while (view.next()) |_| worker_count += 1;
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), worker_count);

    // TransientRefs should NOT be restored
    var transient_count: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{TransientRefs}, .{});
        while (view.next()) |_| transient_count += 1;
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 0), transient_count);
}

test "save/load mixin: Parent component round-trips and remaps entity ID" {
    // Guards the fix for labelle-core #11 / flying-platform-labelle #286.
    // Parent is engine-internal (parameterised over Entity inside
    // `GameConfig`) so it never appears in the game's ComponentRegistry.
    // The save mixin therefore needs to emit it as a built-in (like
    // Position) and rebuild the hierarchy on load via `setParent`.
    // Without that, every child-with-Position drifts to scene origin
    // on load because the Parent edge is silently dropped.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const parent_entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(parent_entity, Position{ .x = 100.0, .y = 50.0 });
    game.active_world.ecs_backend.addComponent(parent_entity, Worker{});

    const child_entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(child_entity, Position{ .x = 15.0, .y = 0.0 });
    game.active_world.ecs_backend.addComponent(child_entity, Health{ .current = 42.0, .max = 100.0 });
    game.setParent(child_entity, parent_entity, .{});

    // Sanity: parent link exists pre-save.
    const Parent = TestGame.ParentComp;
    try testing.expect(game.active_world.ecs_backend.hasComponent(child_entity, Parent));

    const filename = "test_save_parent.json";
    try game.saveGameState(filename);
    defer std.fs.cwd().deleteFile(filename) catch {};

    // Save output should carry a Parent block (built-in, alongside Position).
    {
        const json = try std.fs.cwd().readFileAlloc(testing.allocator, filename, 1024 * 1024);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"Parent\"") != null);
    }

    game.resetEcsBackend();
    try game.loadGameState(filename);

    // Find the post-load parent (Worker marker) and child (Health + Parent).
    var new_parent_id: u64 = 0;
    {
        var view = game.active_world.ecs_backend.view(.{Worker}, .{});
        if (view.next()) |ent| new_parent_id = @intCast(ent);
        view.deinit();
    }
    try testing.expect(new_parent_id != 0);

    var child_seen: usize = 0;
    {
        var view = game.active_world.ecs_backend.view(.{ Health, Parent }, .{});
        while (view.next()) |ent| {
            child_seen += 1;
            const parent_comp = game.active_world.ecs_backend.getComponent(ent, Parent).?;
            // Parent.entity must be remapped through the load id_map —
            // the saved runtime ID wouldn't match after `resetEcsBackend`.
            try testing.expectEqual(new_parent_id, @as(u64, @intCast(parent_comp.entity)));

            // Child's local Position survives save/load (saveable via
            // labelle-core), and rendering should now anchor under the
            // restored parent.
            const pos = game.active_world.ecs_backend.getComponent(ent, Position).?;
            try testing.expectApproxEqAbs(@as(f32, 15.0), pos.x, 0.01);
            try testing.expectApproxEqAbs(@as(f32, 0.0), pos.y, 0.01);
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), child_seen);

    // setParent rebuilds the Children back-link — the parent entity should
    // now list the child among its children.
    const Children = TestGame.ChildrenComp;
    const children_comp = game.active_world.ecs_backend.getComponent(@as(MockEcs.Entity, @intCast(new_parent_id)), Children).?;
    try testing.expectEqual(@as(usize, 1), children_comp.count());
}

test "save/load mixin: load nonexistent file returns error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const result = game.loadGameState("nonexistent_file.json");
    try testing.expectError(error.FileNotFound, result);
}
