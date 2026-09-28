//! engine#896 — a save made after a menu→Load must record the LOADED
//! world's scene, not the menu.
//!
//! A load never swaps scenes (engine#638): after main menu → Load the
//! active scene is still "menu" while the ECS holds the saved gameplay
//! world. Before the fix `serializeGameState` wrote `current_scene_name`
//! as the save's `"scene"`, so saving again from that world produced a
//! `"scene": "menu"` save — and loading it armed the post-load gate on
//! the menu manifest, leaving every gameplay atlas unbound (an invisible
//! world). These tests drive the real serialize/deserialize/setScene path
//! end to end.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Position = core.Position;
const Saveable = core.Saveable;

/// What `worldSceneName()` reported from inside the most recent
/// `Colonist.postLoad` (engine#896 round 1: provenance must be installed
/// BEFORE post-load callbacks run).
var post_load_scene_buf: [64]u8 = undefined;
var post_load_scene: ?[]const u8 = null;

const Colonist = struct {
    pub const save = Saveable(.saveable, @This(), .{});
    hunger: u32 = 0,

    pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
        _ = self;
        _ = entity;
        const name = game.worldSceneName() orelse {
            post_load_scene = null;
            return;
        };
        @memcpy(post_load_scene_buf[0..name.len], name);
        post_load_scene = post_load_scene_buf[0..name.len];
    }
};

const TestComponents = engine.scene_mod.ComponentRegistry(.{
    .Position = Position,
    .Colonist = Colonist,
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

/// The gameplay scene's image manifest — what the restored sprites sample
/// from. Program-lifetime, as `SceneEntry.assets` requires.
const colony_manifest: []const []const u8 = &.{"rooms"};

fn colonyLoader(game: *TestGame) anyerror!void {
    const e = game.createEntity();
    game.active_world.ecs_backend.addComponent(e, Position{ .x = 3, .y = 4 });
    game.active_world.ecs_backend.addComponent(e, Colonist{ .hunger = 7 });
}

fn menuLoader(_: *TestGame) anyerror!void {}

fn registerScenes(game: *TestGame) void {
    game.registerSceneSimple("colony", colonyLoader);
    game.registerSceneSimple("menu", menuLoader);
}

/// Attach the colony manifest + register its (not yet acquired) atlas.
/// Done AFTER the setScene calls so the Debug eager-load fallback and the
/// scene-swap release never touch the stub asset — only the load path's
/// post-load gate acquires it, which is exactly what these tests observe.
fn attachColonyAssets(game: *TestGame) !void {
    try game.assets.register("rooms", .image, "png", "stub");
    try game.atlas_manager.registerPendingAtlas("rooms", "{\"frames\":{}}", "img", "png");
    try game.setSceneAssets("colony", colony_manifest);
}

/// Parse a save and return its `"scene"` (duped into `testing.allocator`),
/// or null when the key is absent.
fn savedScene(bytes: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    const v = parsed.value.object.get("scene") orelse return null;
    return try testing.allocator.dupe(u8, v.string);
}

fn expectSavedScene(bytes: []const u8, expected: []const u8) !void {
    const got = (try savedScene(bytes)) orelse return error.TestExpectedSceneField;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn colonistCount(game: *TestGame) usize {
    var n: usize = 0;
    var view = game.active_world.ecs_backend.view(.{Colonist}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const c = game.active_world.ecs_backend.getComponent(ent, Colonist).?;
        if (c.hunger == 7) n += 1;
    }
    return n;
}

/// A save written from the colony, in a fresh game (session 1).
fn makeColonySave() ![]u8 {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("colony");
    try testing.expectEqual(@as(usize, 1), colonistCount(&game));
    return game.serializeGameState();
}

test "save after menu->Load records the loaded world's scene and reloads it (#896)" {
    // Session 1: play the colony, save.
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);
    try expectSavedScene(save1, "colony");

    // Session 2: main menu -> Load save1 -> save again.
    const save2 = blk: {
        var game = TestGame.init(testing.allocator);
        defer game.deinit();
        registerScenes(&game);
        try game.setScene("menu");
        try attachColonyAssets(&game);

        try game.deserializeGameState(save1);
        // Load did not swap scenes (engine#638) ...
        try testing.expectEqualStrings("menu", game.getCurrentSceneName().?);
        // ... but the world belongs to the colony.
        try testing.expectEqualStrings("colony", game.worldSceneName().?);
        try testing.expectEqual(@as(usize, 1), colonistCount(&game));

        break :blk try game.serializeGameState();
    };
    defer testing.allocator.free(save2);
    // THE regression: this used to be "menu".
    try expectSavedScene(save2, "colony");

    // Session 3: main menu -> Load save2. The world must come back AND the
    // colony's atlases must be the ones the load pinned / gated on.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");
    try attachColonyAssets(&game);

    try game.deserializeGameState(save2);
    try testing.expectEqual(@as(usize, 1), colonistCount(&game));
    // The post-load gate resolved the COLONY manifest (not menu's empty
    // one) and acquired its atlas, so the restored sprites can bind.
    const pinned = game.post_load_acquired_assets orelse return error.TestExpectedColonyManifestPinned;
    try testing.expectEqual(colony_manifest.ptr, pinned.ptr);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("rooms").?.refcount);

    // And a third save still round-trips to the colony.
    const save3 = try game.serializeGameState();
    defer testing.allocator.free(save3);
    try expectSavedScene(save3, "colony");
}

test "a real scene swap after a load drops the loaded scene (#896)" {
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");
    try game.deserializeGameState(save1);
    try testing.expectEqualStrings("colony", game.worldSceneName().?);

    // Back to the menu (e.g. "Quit to menu"): the loaded world is gone, so
    // a save now describes the menu, not the stale colony.
    try game.setScene("menu");
    try testing.expect(game.active_world.loaded_save_scene_name == null);
    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try expectSavedScene(bytes, "menu");
}

test "loading a legacy save without a scene falls back to the active scene (#896)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");

    // First adopt a scene from a modern save, then load a legacy one: the
    // stale "colony" override must not leak into the legacy world.
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);
    try game.deserializeGameState(save1);
    try testing.expectEqualStrings("colony", game.worldSceneName().?);

    // Legacy = the same save with its `"scene"` line stripped (pre-#638).
    const scene_line = "  \"scene\": \"colony\",\n";
    const legacy = try std.mem.replaceOwned(u8, testing.allocator, save1, scene_line, "");
    defer testing.allocator.free(legacy);
    try testing.expect(legacy.len < save1.len);
    try testing.expect((try savedScene(legacy)) == null);
    try game.deserializeGameState(legacy);
    try testing.expect(game.active_world.loaded_save_scene_name == null);
    try testing.expectEqualStrings("menu", game.worldSceneName().?);
}

// ── Round-1 review fixes: provenance is per-World and cleared by the
//    primitives that rebuild the world (engine#898 review) ──────────────

test "switching active worlds switches scene provenance (#896)" {
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");

    // Load into a NAMED world so it survives being shelved.
    try game.createWorld("a");
    try game.setActiveWorld("a");
    try game.deserializeGameState(save1);
    try testing.expectEqualStrings("colony", game.worldSceneName().?);

    // A fresh world holds none of the loaded entities: it must not
    // inherit the colony provenance.
    try game.createWorld("b");
    try game.setActiveWorld("b");
    try testing.expect(game.active_world.loaded_save_scene_name == null);
    try testing.expectEqualStrings("menu", game.worldSceneName().?);
    {
        const bytes = try game.serializeGameState();
        defer testing.allocator.free(bytes);
        try expectSavedScene(bytes, "menu");
    }

    // Switching back restores the provenance WITH its entities.
    try game.setActiveWorld("a");
    try testing.expectEqual(@as(usize, 1), colonistCount(&game));
    try testing.expectEqualStrings("colony", game.worldSceneName().?);
    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try expectSavedScene(bytes, "colony");
}

test "hot reload rebuilding the scene drops the loaded provenance (#896)" {
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");
    try game.deserializeGameState(save1);
    try testing.expectEqualStrings("colony", game.worldSceneName().?);

    // Hot reload: `unloadCurrentScene()` + the menu loader rerun. The
    // restored colony world is gone, so a save now describes the menu.
    game.hot_reload_dirty = true;
    game.tick(0.016);
    try testing.expect(!game.hot_reload_dirty);
    try testing.expect(game.active_world.loaded_save_scene_name == null);
    try testing.expectEqualStrings("menu", game.worldSceneName().?);
    const bytes = try game.serializeGameState();
    defer testing.allocator.free(bytes);
    try expectSavedScene(bytes, "menu");
}

/// Passes everything through to `child` except an allocation of exactly
/// `fail_len` bytes while armed — used to fail precisely the saved-scene
/// name copy (the name below has a length nothing else on the
/// pre-reset load path requests).
const FailOnLen = struct {
    child: std.mem.Allocator,
    fail_len: ?usize = null,
    failed: bool = false,

    fn allocator(self: *FailOnLen) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailOnLen = @ptrCast(@alignCast(ctx));
        if (self.fail_len) |n| if (n == len) {
            self.failed = true;
            return null;
        };
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *FailOnLen = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *FailOnLen = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *FailOnLen = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

const distinct_scene = "outpost_scene_with_a_deliberately_odd_name_length_x";

test "OOM copying the saved scene errors and leaves the old world intact (#896)" {
    // Session 1: a save whose scene has a distinctive name length.
    const save1 = blk: {
        var game = TestGame.init(testing.allocator);
        defer game.deinit();
        game.registerSceneSimple(distinct_scene, colonyLoader);
        try game.setScene(distinct_scene);
        break :blk try game.serializeGameState();
    };
    defer testing.allocator.free(save1);
    try expectSavedScene(save1, distinct_scene);

    var fal: FailOnLen = .{ .child = testing.allocator };
    var game = TestGame.init(fal.allocator());
    defer game.deinit();
    registerScenes(&game);
    game.registerSceneSimple(distinct_scene, colonyLoader);
    try game.setScene("menu");

    // The live world: one marker entity the save does not contain.
    const marker = game.createEntity();
    game.active_world.ecs_backend.addComponent(marker, Colonist{ .hunger = 99 });

    fal.fail_len = distinct_scene.len;
    try testing.expectError(error.OutOfMemory, game.deserializeGameState(save1));
    fal.fail_len = null;
    // The name copy is what failed (not some later allocation) ...
    try testing.expect(fal.failed);
    // ... and it failed BEFORE the reset: the old world is untouched.
    try testing.expectEqual(@as(u32, 99), game.active_world.ecs_backend.getComponent(marker, Colonist).?.hunger);
    try testing.expectEqual(@as(usize, 0), colonistCount(&game));
    try testing.expectEqualStrings("menu", game.worldSceneName().?);

    // Without the fault the same save loads and adopts the scene.
    try game.deserializeGameState(save1);
    try testing.expectEqual(@as(usize, 1), colonistCount(&game));
    try testing.expectEqualStrings(distinct_scene, game.worldSceneName().?);
}

test "postLoad callbacks observe the loaded scene (#896)" {
    const save1 = try makeColonySave();
    defer testing.allocator.free(save1);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");

    post_load_scene = null;
    try game.deserializeGameState(save1);
    const seen = post_load_scene orelse return error.TestPostLoadNotRun;
    try testing.expectEqualStrings("colony", seen);
}

test "an unregistered saved scene resaves as the fallback scene (#896)" {
    // Session 1: the scene was called `colony_v1` when saved.
    const save1 = blk: {
        var game = TestGame.init(testing.allocator);
        defer game.deinit();
        game.registerSceneSimple("colony_v1", colonyLoader);
        try game.setScene("colony_v1");
        break :blk try game.serializeGameState();
    };
    defer testing.allocator.free(save1);
    try expectSavedScene(save1, "colony_v1");

    // Session 2: renamed to `colony`; load the old save while in it. The
    // render gate falls back to the active scene, so provenance must too.
    const save2 = blk: {
        var game = TestGame.init(testing.allocator);
        defer game.deinit();
        registerScenes(&game);
        try game.setScene("colony");
        try game.deserializeGameState(save1);
        try testing.expect(game.active_world.loaded_save_scene_name == null);
        try testing.expectEqualStrings("colony", game.worldSceneName().?);
        break :blk try game.serializeGameState();
    };
    defer testing.allocator.free(save2);
    // Resolves, unlike `colony_v1`: a later menu→Load gates on colony.
    try expectSavedScene(save2, "colony");

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    registerScenes(&game);
    try game.setScene("menu");
    try game.deserializeGameState(save2);
    try testing.expectEqualStrings("colony", game.worldSceneName().?);
}
