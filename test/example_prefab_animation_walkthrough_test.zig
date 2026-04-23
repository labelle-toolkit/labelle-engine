//! # Prefab + Animation + Save/Load — End-to-End Walkthrough
//!
//! Narrative example of the machinery introduced across PRs #474,
//! #482, #483, #484, #485, #475, #476, #480, #481 (all landed on
//! `main`). Reads top-to-bottom as a story:
//!
//!   1. Declare a prefab jsonc with a `PlantLevel` driver on the root
//!      and two child entities with `Sprite` placeholders.
//!   2. Spawn the prefab via `game.spawnFromPrefab`. The engine
//!      attaches `PrefabInstance` to the root and `PrefabChild` to
//!      each descendant with an arena-duped `local_path`.
//!   3. Programmatically attach `SpriteAnimation` + `SpriteByField`
//!      to the two children (see the "Known gap" note below).
//!   4. Tick the animation systems and verify the sprite names on the
//!      children flip correctly.
//!   5. Save, `resetEcsBackend`, load. Phase 1 re-spawns the prefab
//!      from its path and maps saved child IDs via `(root,
//!      local_path)`; Phase 2 reapplies saved registered-component
//!      values on top.
//!   6. Assert the post-load world preserves the saveable game state
//!      (`PlantLevel`) and the prefab-declared children (via respawn),
//!      then re-attach the animation components to demonstrate that a
//!      fresh tick pass resolves them against the restored state.
//!
//! ## Known gap: SpriteAnimation / SpriteByField from jsonc
//!
//! The intended downstream workflow (per the prefab-animation RFC) is
//! to declare `SpriteAnimation` and `SpriteByField` inline inside the
//! prefab jsonc, and rely on `game.spawnFromPrefab` + Phase 1 respawn
//! to bring them back on load. That path currently doesn't work:
//! `src/jsonc_scene_bridge.zig::deserialize` only handles primitives +
//! `[]const u8` + enum + struct/union, so the slice-of-struct /
//! slice-of-string fields on these components silently fail to
//! deserialize and the component is skipped at spawn time.
//!
//! The components' save policies are `.transient` — intentionally, so
//! they DON'T round-trip through the save file — meaning the re-attach
//! in step 6 is the game author's responsibility today. A follow-up
//! should extend the bridge's deserializer to handle these shapes, at
//! which point the manual re-attach here and the game-side scripts
//! that currently do the same work can both go away.
//!
//! ## How to read the rest
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
    .PlantLevel = PlantLevel,
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

/// Only fields the bridge's deserializer can handle today: `Position`
/// (built-in), `PlantLevel` (registered, primitive fields), and
/// `Sprite` (built-in). The animation components are attached in
/// step 3 below.
const PLANT_PREFAB =
    \\{
    \\  "components": {
    \\    "PlantLevel": { "level": 2 }
    \\  },
    \\  "children": [
    \\    { "components": { "Sprite": { "sprite_name": "pipe_0001.png" } } },
    \\    { "components": { "Sprite": { "sprite_name": "leaf_lvl0.png" } } }
    \\  ]
    \\}
;

// Frame table for the animation child. Program lifetime; the
// component borrows this slice (it doesn't own its `frames` memory).
const PIPE_FRAMES = [_][]const u8{ "pipe_0001.png", "pipe_0002.png", "pipe_0003.png" };

// Lookup table for the field-driven child. Same lifetime story.
const LEAF_ENTRIES = [_]SpriteByField.Entry{
    .{ .key = 0, .sprite_name = null },
    .{ .key = 1, .sprite_name = "leaf_lvl1.png" },
    .{ .key = 2, .sprite_name = "leaf_lvl2.png" },
    .{ .key = 3, .sprite_name = "leaf_lvl3.png" },
};

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

/// Extract (anim, field) child entities by their prefab index. The
/// walkthrough attaches SpriteAnimation to child 0 and SpriteByField
/// to child 1 — both before tick and again after load, since neither
/// component survives save (`.transient`) nor jsonc deserialize today.
fn attachAnimationComponents(game: *TestGame) !struct { anim: TestGame.EntityType, field: TestGame.EntityType } {
    var children = try findPrefabChildren(game, testing.allocator);
    defer children.deinit();
    const anim_child = children.get(0).?;
    const field_child = children.get(1).?;

    game.ecs_backend.addComponent(anim_child, SpriteAnimation{
        .frames = &PIPE_FRAMES,
        .fps = 6,
        .mode = .loop,
    });
    game.ecs_backend.addComponent(field_child, SpriteByField{
        .component = "PlantLevel",
        .field = "level",
        .source = .parent,
        .entries = &LEAF_ENTRIES,
    });

    return .{ .anim = anim_child, .field = field_child };
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
    // the two children and attached PrefabInstance / PrefabChild tags
    // so the save mixin can reinstantiate on load.
    const root_pre = game.spawnFromPrefab("plant", .{ .x = 0, .y = 0 }).?;

    // Root carries its PrefabInstance tag with the arena-duped path.
    const pi = game.ecs_backend.getComponent(root_pre, PrefabInstance).?;
    try testing.expectEqualStrings("plant", pi.path);

    // Saveable driver came from the prefab's `"components"` block.
    try testing.expectEqual(@as(i32, 2), game.ecs_backend.getComponent(root_pre, PlantLevel).?.level);

    // ── Step 2: attach animation components programmatically ────
    //
    // See the "Known gap" note above. In a future revision these
    // would be declared inline in the prefab jsonc.
    const pre = try attachAnimationComponents(game);

    // Sprite starts at the prefab's declared frame / placeholder.
    try testing.expectEqualStrings(
        "pipe_0001.png",
        game.ecs_backend.getComponent(pre.anim, Sprite).?.sprite_name,
    );
    try testing.expectEqualStrings(
        "leaf_lvl0.png",
        game.ecs_backend.getComponent(pre.field, Sprite).?.sprite_name,
    );

    // ── Step 3: tick the animation systems ──────────────────────
    //
    // One full frame duration at 6 fps flips the anim child 0 → 1.
    // The field child resolves `PlantLevel.level` (= 2) and picks
    // `leaf_lvl2.png` on the first tick.
    engine.spriteAnimationTick(game, 1.0 / 6.0);
    engine.spriteByFieldTick(game, 0);

    try testing.expectEqualStrings(
        "pipe_0002.png",
        game.ecs_backend.getComponent(pre.anim, Sprite).?.sprite_name,
    );
    try testing.expectEqualStrings(
        "leaf_lvl2.png",
        game.ecs_backend.getComponent(pre.field, Sprite).?.sprite_name,
    );

    // Change the driver and re-tick — the field child flips to
    // level 3.
    game.ecs_backend.getComponent(root_pre, PlantLevel).?.level = 3;
    engine.spriteByFieldTick(game, 0);
    try testing.expectEqualStrings(
        "leaf_lvl3.png",
        game.ecs_backend.getComponent(pre.field, Sprite).?.sprite_name,
    );

    // ── Step 4: save + reset + load ─────────────────────────────
    //
    // Two-phase load respawns the prefab (Phase 1) and applies the
    // saved `PlantLevel` override on top (Phase 2). Sprite is
    // non-saveable but comes back from the prefab's declared
    // `"Sprite"` on each child. SpriteAnimation / SpriteByField are
    // `.transient`, so neither appears in the save file — that's
    // why step 5 re-attaches them.
    const save_path = try std.fmt.allocPrint(testing.allocator, "{s}/save.json", .{fixture.prefab_dir});
    defer testing.allocator.free(save_path);
    defer std.fs.cwd().deleteFile(save_path) catch {};

    try game.saveGameState(save_path);
    game.resetEcsBackend();
    try game.loadGameState(save_path);

    // ── Step 5: verify structural round-trip ───────────────────
    //
    // Every entity has a new ECS handle (the save ids don't survive
    // the reset), but the shape matches: one prefab root tagged
    // with PrefabInstance, two children tagged with PrefabChild at
    // `children[0]` and `children[1]`.
    const root_post = findRoot(game);
    var post_children = try findPrefabChildren(game, testing.allocator);
    defer post_children.deinit();
    try testing.expectEqual(@as(u32, 2), post_children.count());

    // PlantLevel survived at its last-written value (= 3).
    try testing.expectEqual(@as(i32, 3), game.ecs_backend.getComponent(root_post, PlantLevel).?.level);

    // Sprite came back "for free" via the prefab respawn — no
    // game-side `restoreSprites` hook was involved.
    const anim_child_post = post_children.get(0).?;
    const field_child_post = post_children.get(1).?;
    try testing.expectEqualStrings(
        "pipe_0001.png",
        game.ecs_backend.getComponent(anim_child_post, Sprite).?.sprite_name,
    );
    try testing.expectEqualStrings(
        "leaf_lvl0.png",
        game.ecs_backend.getComponent(field_child_post, Sprite).?.sprite_name,
    );

    // ── Step 6: re-attach animation + verify fresh tick resolves ─
    //
    // A fresh tick pass resolves `SpriteByField` against the restored
    // level-3 state on the first frame, no warmup needed. When the
    // bridge learns to deserialize these components, this step goes
    // away — they'll already be attached by the prefab respawn in
    // Phase 1.
    const post = try attachAnimationComponents(game);
    engine.spriteAnimationTick(game, 1.0 / 6.0);
    engine.spriteByFieldTick(game, 0);

    try testing.expectEqualStrings(
        "pipe_0002.png",
        game.ecs_backend.getComponent(post.anim, Sprite).?.sprite_name,
    );
    try testing.expectEqualStrings(
        "leaf_lvl3.png",
        game.ecs_backend.getComponent(post.field, Sprite).?.sprite_name,
    );
}
