//! # Prefab + Animation + Save/Load — End-to-End Walkthrough
//!
//! Narrative example of the machinery introduced across PRs #474,
//! #482, #483, #484, #485, #475, #476, #480, #481, plus the bridge
//! slice-deserializer extension for #487. Reads top-to-bottom as a
//! story:
//!
//!   1. Declare a prefab jsonc that combines
//!      `PlantLevel` (saveable driver) + `Sprite` + `SpriteAnimation`
//!      (frame cycle) + `SpriteByField` (level-driven sprite swap).
//!   2. Spawn the prefab via `game.spawnFromPrefab`. The engine
//!      attaches `PrefabInstance` to the root and `PrefabChild` to
//!      each descendant with an arena-duped `local_path`, and the
//!      JSONC bridge deserializes every component — including
//!      `SpriteAnimation.frames` (slice of strings) and
//!      `SpriteByField.entries` (slice of structs with `?[]const u8`
//!      fields) — directly from the prefab.
//!   3. Tick the animation systems and verify the sprite names on
//!      each child flip correctly.
//!   4. Save, `resetEcsBackend`, load. Phase 1 re-spawns the prefab
//!      from its path and maps saved child IDs via `(root,
//!      local_path)`; Phase 2 reapplies saved registered-component
//!      values on top; `SpriteAnimation` / `SpriteByField` are
//!      `.transient` and come back via the Phase 1 respawn rather
//!      than the save file.
//!   5. Assert the post-load world preserves the saveable game state
//!      (`PlantLevel` at its last-written value) and the prefab-
//!      declared animation components (via respawn); a single post-
//!      load tick re-resolves the field-driven child against the
//!      restored level.
//!
//! Runnable under `zig build test`. Uses `MockEcs` + `StubRender` so
//! there's no window, GPU, or atlas — the pipeline itself is what
//! gets exercised. For per-PR focused tests see
//! `spawn_from_prefab_test.zig`, `save_load_two_phase_test.zig`,
//! `jsonc_bridge_prefab_tags_test.zig`,
//! `sprite_animation_tick_test.zig`, `sprite_by_field_tick_test.zig`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

// ─── Game-side component ─────────────────────────────────────────

/// Saveable driver on the prefab root. `SpriteByField` on the overlay
/// child reads this through `.source = .parent` to decide which frame
/// to show. `.saveable` is required so the save mixin collects this
/// entity at all — `PrefabInstance` alone isn't enough (see
/// `game.spawnFromPrefab` docstring).
const PlantLevel = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    level: i32 = 0,
};

const TestComponents = engine.ComponentRegistry(.{
    // Game-owned saveable driver.
    .PlantLevel = PlantLevel,
    // Animation components must be registered so the JSONC bridge
    // will deserialize them out of the prefab's `"components"` block.
    // Their save policies are `.transient` — they don't round-trip
    // through the save file, they come back via prefab respawn.
    .SpriteAnimation = engine.SpriteAnimation,
    .SpriteByField = engine.SpriteByField,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

const Bridge = engine.JsoncSceneBridge(TestGame, TestComponents);
const Sprite = TestGame.SpriteComp;
const SpriteAnimation = engine.SpriteAnimation;
const SpriteByField = engine.SpriteByField;
const PrefabInstance = TestGame.PrefabInstanceComp;
const PrefabChild = TestGame.PrefabChildComp;

// ─── Prefab definition ───────────────────────────────────────────

/// Root: `PlantLevel` (saveable).
/// Child 0: pipe-cycle `Sprite` + `SpriteAnimation`.
/// Child 1: level-driven `Sprite` + `SpriteByField` reading
/// `PlantLevel.level` from the parent. `entries` contains a `null`
/// sprite name for level 0 (hide) plus three real frames.
const PLANT_PREFAB =
    \\{
    \\  "components": {
    \\    "PlantLevel": { "level": 2 }
    \\  },
    \\  "children": [
    \\    {
    \\      "components": {
    \\        "Sprite": { "sprite_name": "pipe_0001.png" },
    \\        "SpriteAnimation": {
    \\          "frames": ["pipe_0001.png", "pipe_0002.png", "pipe_0003.png"],
    \\          "fps": 6,
    \\          "mode": "loop"
    \\        }
    \\      }
    \\    },
    \\    {
    \\      "components": {
    \\        "Sprite": { "sprite_name": "leaf_lvl1.png" },
    \\        "SpriteByField": {
    \\          "component": "PlantLevel",
    \\          "field": "level",
    \\          "source": "parent",
    \\          "entries": [
    \\            { "key": 0, "sprite_name": null },
    \\            { "key": 1, "sprite_name": "leaf_lvl1.png" },
    \\            { "key": 2, "sprite_name": "leaf_lvl2.png" },
    \\            { "key": 3, "sprite_name": "leaf_lvl3.png" }
    \\          ]
    \\        }
    \\      }
    \\    }
    \\  ]
    \\}
;

// ─── Fixture plumbing ────────────────────────────────────────────

const Fixture = struct {
    game: TestGame,
    prefab_dir: []const u8,

    fn deinit(self: *Fixture) void {
        self.game.deinit();
        testing.allocator.free(self.prefab_dir);
    }
};

fn boot(tmp_dir: *std.testing.TmpDir) !Fixture {
    try tmp_dir.dir.makeDir("prefabs");
    try tmp_dir.dir.writeFile(.{ .sub_path = "prefabs/plant.jsonc", .data = PLANT_PREFAB });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
    const prefab_dir = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{dir_path});
    errdefer testing.allocator.free(prefab_dir);

    var game = TestGame.init(testing.allocator);
    errdefer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\{ "entities": [] }
    , prefab_dir);

    return .{ .game = game, .prefab_dir = prefab_dir };
}

fn findRoot(game: *TestGame) TestGame.EntityType {
    var view = game.ecs_backend.view(.{PrefabInstance}, .{});
    defer view.deinit();
    return view.next().?;
}

/// (child_index → entity) mapping from the PrefabChild tags so the
/// walkthrough can address "the animation child" and "the lookup
/// child" by their prefab slot.
fn findPrefabChildren(game: *TestGame, allocator: std.mem.Allocator) !std.AutoHashMap(u32, TestGame.EntityType) {
    var children = std.AutoHashMap(u32, TestGame.EntityType).init(allocator);
    var view = game.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const pc = game.ecs_backend.getComponent(ent, PrefabChild).?;
        if (std.mem.startsWith(u8, pc.local_path, "children[")) {
            const close = std.mem.indexOfScalar(u8, pc.local_path, ']') orelse continue;
            const idx = std.fmt.parseInt(u32, pc.local_path["children[".len..close], 10) catch continue;
            try children.put(idx, ent);
        }
    }
    return children;
}

// ─── The walkthrough ─────────────────────────────────────────────

test "walkthrough: prefab + animation + save/load round-trips end-to-end" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try boot(&tmp_dir);
    defer fixture.deinit();
    const game = &fixture.game;

    // ── Step 1: spawn the prefab ────────────────────────────────
    //
    // Returns the root entity. Under the hood the bridge also spawned
    // the two children, deserialized every component listed in the
    // prefab (including the slice-of-string `frames` and slice-of-
    // struct `entries` that #487 unblocked), and attached
    // PrefabInstance / PrefabChild tags so the save mixin can
    // reinstantiate on load.
    const root_pre = game.spawnFromPrefab("plant", .{ .x = 0, .y = 0 }).?;

    // Root carries its PrefabInstance tag with the arena-duped path
    // and the saveable game state the prefab declared.
    const pi = game.ecs_backend.getComponent(root_pre, PrefabInstance).?;
    try testing.expectEqualStrings("plant", pi.path);
    try testing.expectEqual(@as(i32, 2), game.ecs_backend.getComponent(root_pre, PlantLevel).?.level);

    // Locate the two children by prefab index.
    var pre_children = try findPrefabChildren(game, testing.allocator);
    defer pre_children.deinit();
    const anim_child_pre = pre_children.get(0).?;
    const field_child_pre = pre_children.get(1).?;

    // Both animation components came through the JSONC bridge —
    // `frames` populated from the array-of-strings, `entries` from
    // the array-of-objects (with the `null` sprite_name properly
    // hitting the optional path).
    const anim_pre = game.ecs_backend.getComponent(anim_child_pre, SpriteAnimation).?;
    try testing.expectEqual(@as(usize, 3), anim_pre.frames.len);
    try testing.expectEqualStrings("pipe_0002.png", anim_pre.frames[1]);

    const field_pre = game.ecs_backend.getComponent(field_child_pre, SpriteByField).?;
    try testing.expectEqual(@as(usize, 4), field_pre.entries.len);
    try testing.expect(field_pre.entries[0].sprite_name == null); // level 0 = hide
    try testing.expectEqualStrings("leaf_lvl3.png", field_pre.entries[3].sprite_name.?);

    // ── Step 2: tick the animation systems ──────────────────────
    //
    // One full frame duration at 6 fps flips the anim child 0 → 1.
    // The field child reads `PlantLevel.level` (= 2) off the parent
    // and picks `leaf_lvl2.png` on the first tick.
    engine.spriteAnimationTick(game, 1.0 / 6.0);
    engine.spriteByFieldTick(game, 0);

    try testing.expectEqualStrings(
        "pipe_0002.png",
        game.ecs_backend.getComponent(anim_child_pre, Sprite).?.sprite_name,
    );
    try testing.expectEqualStrings(
        "leaf_lvl2.png",
        game.ecs_backend.getComponent(field_child_pre, Sprite).?.sprite_name,
    );

    // Change the driver and re-tick — the field child flips to
    // level 3.
    game.ecs_backend.getComponent(root_pre, PlantLevel).?.level = 3;
    engine.spriteByFieldTick(game, 0);
    try testing.expectEqualStrings(
        "leaf_lvl3.png",
        game.ecs_backend.getComponent(field_child_pre, Sprite).?.sprite_name,
    );

    // ── Step 3: save + reset + load ─────────────────────────────
    //
    // Two-phase load respawns the prefab (Phase 1) and applies the
    // saved `PlantLevel` override on top (Phase 2). `Sprite` is
    // non-saveable but comes back from the prefab's declared
    // `"Sprite"` on each child. `SpriteAnimation` / `SpriteByField`
    // are `.transient` — they don't appear in the save file at all,
    // they come back via the Phase 1 prefab respawn.
    const save_path = try std.fmt.allocPrint(testing.allocator, "{s}/save.json", .{fixture.prefab_dir});
    defer testing.allocator.free(save_path);
    defer std.fs.cwd().deleteFile(save_path) catch {};

    try game.saveGameState(save_path);
    game.resetEcsBackend();
    try game.loadGameState(save_path);

    // ── Step 4: verify round-trip ───────────────────────────────
    //
    // Every entity has a new ECS handle (the save ids don't survive
    // the reset), but the shape matches: one prefab root tagged
    // with PrefabInstance, two children tagged with PrefabChild at
    // `children[0]` and `children[1]`.
    const root_post = findRoot(game);
    var post_children = try findPrefabChildren(game, testing.allocator);
    defer post_children.deinit();
    try testing.expectEqual(@as(u32, 2), post_children.count());
    const anim_child_post = post_children.get(0).?;
    const field_child_post = post_children.get(1).?;

    // PlantLevel survived at its last-written value (= 3).
    try testing.expectEqual(@as(i32, 3), game.ecs_backend.getComponent(root_post, PlantLevel).?.level);

    // SpriteAnimation is attached again via the prefab respawn —
    // with its runtime state freshly zeroed (`frame = 0`).
    try testing.expect(game.ecs_backend.hasComponent(anim_child_post, SpriteAnimation));
    const anim_post = game.ecs_backend.getComponent(anim_child_post, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 0), anim_post.frame);
    try testing.expectEqual(@as(usize, 3), anim_post.frames.len);

    // SpriteByField is attached again too. A single post-load tick
    // resolves it against the restored level (= 3) without any
    // warmup — no game-side re-hydration hook required.
    try testing.expect(game.ecs_backend.hasComponent(field_child_post, SpriteByField));
    engine.spriteByFieldTick(game, 0);
    try testing.expectEqualStrings(
        "leaf_lvl3.png",
        game.ecs_backend.getComponent(field_child_post, Sprite).?.sprite_name,
    );
}
