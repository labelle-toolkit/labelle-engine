const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const GameConfig = engine.GameConfig;
const GameWith = engine.GameWith;
const StubRender = engine.StubRender;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;
const InputInterface = engine.InputInterface;
const AudioInterface = engine.AudioInterface;
const GuiInterface = engine.GuiInterface;
const ParentComponent = engine.ParentComponent;

test "Game: full lifecycle with StubRender" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "player" });
    game.setPosition(entity, .{ .x = 100, .y = 200 });

    game.tick(0.016);
    game.render();

    try testing.expectEqual(1, game.entityCount());
}

test "GameConfig: RenderImpl slot is parameterized" {
    const TestRenderer = StubRender(u32);
    const EmptyComponents = struct {
        pub fn has(comptime _: []const u8) bool { return false; }
        pub fn names() []const []const u8 { return &.{}; }
    };
    const CustomGame = GameConfig(
        TestRenderer,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{}, // no gizmo categories
        void, // no game events
    );

    var game = CustomGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addShape(entity, .{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    });
    game.setPosition(entity, .{ .x = 200, .y = 300 });

    game.tick(0.016);
    game.render();

    try testing.expectEqual(1, game.entityCount());
}

test "GameWith(Hooks): lifecycle hooks fire" {
    const MyHooks = struct {
        entity_count: u32 = 0,
        frame_count: u32 = 0,

        pub fn entity_created(self: *@This(), _: anytype) void {
            self.entity_count += 1;
        }
        pub fn frame_start(self: *@This(), _: anytype) void {
            self.frame_count += 1;
        }
    };

    var hooks = MyHooks{};
    var game = GameWith(*MyHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    _ = game.createEntity();
    _ = game.createEntity();
    game.tick(0.016);

    try testing.expectEqual(2, hooks.entity_count);
    try testing.expectEqual(1, hooks.frame_count);
}

test "InputInterface(StubInput) compiles" {
    const InputI = InputInterface(StubInput);
    try testing.expect(!InputI.isKeyDown(0));
    try testing.expect(!InputI.isKeyPressed(0));
    try testing.expectEqual(0.0, InputI.getMouseX());
}

test "AudioInterface(StubAudio) compiles" {
    const AudioI = AudioInterface(StubAudio);
    AudioI.playSound(0);
    AudioI.stopSound(0);
    AudioI.setVolume(0.5);
}

test "GuiInterface(StubGui) compiles" {
    const GuiI = GuiInterface(StubGui);
    GuiI.begin();
    GuiI.end();
    try testing.expect(!GuiI.wantsMouse());
    try testing.expect(!GuiI.wantsKeyboard());
}

test "Game: GUI forwarding methods work" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.guiBegin();
    game.guiEnd();
    try testing.expect(!game.guiWantsMouse());
    try testing.expect(!game.guiWantsKeyboard());
}

test "Game: scene management" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loadTestScene = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.addSprite(e, .{ .sprite_name = "test" });
            g.setPosition(e, .{ .x = 50, .y = 50 });
        }
    }.load;

    game.registerSceneSimple("test", loadTestScene);
    try game.setScene("test");

    try testing.expectEqualStrings("test", game.getCurrentSceneName().?);
    try testing.expectEqual(1, game.entityCount());
}

test "Game: SceneEntry.assets defaults to empty for legacy registration" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("legacy", emptyLoader);

    const entry = game.scenes.get("legacy").?;
    try testing.expectEqual(@as(usize, 0), entry.assets.len);
}

test "Game: registerSceneWithAssets attaches manifest slice" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    const menu_assets: []const []const u8 = &.{ "background", "ship" };
    game.registerSceneWithAssets("main", emptyLoader, menu_assets);

    const entry = game.scenes.get("main").?;
    try testing.expectEqual(@as(usize, 2), entry.assets.len);
    try testing.expectEqualStrings("background", entry.assets[0]);
    try testing.expectEqualStrings("ship", entry.assets[1]);
}

test "Game: setSceneAssets threads manifest into existing SceneEntry" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("menu", emptyLoader);

    // Before — legacy default.
    try testing.expectEqual(@as(usize, 0), game.scenes.get("menu").?.assets.len);

    const menu_assets: []const []const u8 = &.{ "background", "ship" };
    try game.setSceneAssets("menu", menu_assets);

    const entry = game.scenes.get("menu").?;
    try testing.expectEqual(@as(usize, 2), entry.assets.len);
    try testing.expectEqualStrings("background", entry.assets[0]);
    try testing.expectEqualStrings("ship", entry.assets[1]);

    // Unknown scene returns an error instead of silently dropping.
    try testing.expectError(error.SceneNotFound, game.setSceneAssets("nope", menu_assets));
}

test "Game: SceneEntry.initial_state defaults to null for legacy registration" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("legacy", emptyLoader);

    try testing.expect(game.scenes.get("legacy").?.initial_state == null);
}

test "Game: setSceneInitialState threads state into existing SceneEntry" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("combat_arena", emptyLoader);

    // Before — legacy default.
    try testing.expect(game.scenes.get("combat_arena").?.initial_state == null);

    try game.setSceneInitialState("combat_arena", "playing");
    try testing.expectEqualStrings("playing", game.scenes.get("combat_arena").?.initial_state.?);

    // Unknown scene returns an error instead of silently dropping.
    try testing.expectError(error.SceneNotFound, game.setSceneInitialState("nope", "playing"));
}

test "Game: setScene honors SceneEntry.initial_state and transitions game_state" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("combat_arena", emptyLoader);
    try game.setSceneInitialState("combat_arena", "playing");

    // Default starting state — see game.zig:261.
    try testing.expectEqualStrings("running", game.getState());

    try game.setScene("combat_arena");

    try testing.expectEqualStrings("playing", game.getState());
}

test "Game: setScene without initial_state leaves game_state untouched" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("plain", emptyLoader);

    // Caller-set initial state must survive a setScene() with no
    // initial_state declared on the scene — opt-in behavior.
    game.setState("custom_state");

    try game.setScene("plain");

    try testing.expectEqualStrings("custom_state", game.getState());
}

test "Game: setSceneAtomic honors SceneEntry.initial_state (mirrors setScene)" {
    // Regression check: setSceneAtomic was the parallel code path that
    // initially missed the initial_state handling — flagged by Cursor /
    // gemini on PR #501. Both setScene and setSceneAtomic must apply
    // the declared state, otherwise scenes loaded atomically silently
    // ignore their preference (the exact bug #500 was filed to fix).
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("combat_arena", emptyLoader);
    try game.setSceneInitialState("combat_arena", "playing");

    try testing.expectEqualStrings("running", game.getState());

    try game.setSceneAtomic("combat_arena");

    try testing.expectEqualStrings("playing", game.getState());
}

test "Game: setScene with no manifest acquires all registered assets in Debug (issue #502)" {
    // The eager-fallback is comptime-gated to `builtin.mode == .Debug`.
    // The test binary IS a Debug build (Zig's default for `zig build test`),
    // so this exercises the production-path-of-record behavior.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("background", .image, "png", "fake-bytes-1");
    try game.assets.register("ship", .image, "png", "fake-bytes-2");

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    // Scene registered without a manifest — exactly the case #502 fixes.
    game.registerSceneSimple("debug/peek", emptyLoader);

    // Pre-condition: no acquires yet.
    try testing.expectEqual(@as(u32, 0), game.assets.entries.get("background").?.refcount);
    try testing.expectEqual(@as(u32, 0), game.assets.entries.get("ship").?.refcount);

    // setScene defers the swap (assets aren't .ready without a backend),
    // but the eager-fallback should still have acquire'd them — that's
    // the half of the gate this test pins. The deferred swap is fine.
    _ = game.setScene("debug/peek") catch {};

    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("background").?.refcount);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("ship").?.refcount);
}

test "Game: setScene with explicit manifest does NOT eager-load other resources" {
    // The fallback only fires when the scene's `assets:` is empty —
    // a scene that explicitly opts in to one resource shouldn't
    // accidentally pull in the rest of the project's catalog.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("declared", .image, "png", "a");
    try game.assets.register("not_declared", .image, "png", "b");

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("scoped", emptyLoader);
    const manifest: []const []const u8 = &.{"declared"};
    try game.setSceneAssets("scoped", manifest);

    _ = game.setScene("scoped") catch {};

    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("declared").?.refcount);
    try testing.expectEqual(@as(u32, 0), game.assets.entries.get("not_declared").?.refcount);
}

test "Game: pendingSceneName returns null when no swap is in flight" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.pendingSceneName() == null);
}

test "Game: pendingSceneName returns target name during asset-loading deferral (issue #504)" {
    // Reproduces the race from issue #504: setScene's manifest gate
    // defers while atlases decode. During that window, consumers used
    // to see `getCurrentSceneName() == null` and erroneously assume
    // no scene was loaded. `pendingSceneName()` lets them tell the
    // difference between "no swap requested" and "swap in flight".
    //
    // Use a declared manifest (not the eager-fallback) so the gate
    // engages and defers. Post-#506 the eager-fallback path skips
    // the gate, so this test must explicitly set assets to exercise
    // the deferral semantics it cares about.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("background", .image, "png", "fake-bytes");

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("late_loader", emptyLoader);
    const manifest: []const []const u8 = &.{"background"};
    try game.setSceneAssets("late_loader", manifest);

    // Asset is .registered (not .ready) — gate will defer.
    _ = game.setScene("late_loader") catch {};

    // Committed scene is still null (gate deferred), but the pending
    // marker reflects the user's intent.
    try testing.expect(game.getCurrentSceneName() == null);
    try testing.expectEqualStrings("late_loader", game.pendingSceneName().?);
}

test "Game: eager-fallback completes setScene even when assets aren't .ready (issue #506)" {
    // Regression check: pre-#506 the eager-fallback routed through the
    // same allReady gate as a declared manifest, so a setScene call
    // would defer forever — no retrier exists for non-main scenes,
    // and the assembler-emitted main.zig only calls setScene once.
    // The fix: eager-fallback path uses acquireImmediately, accepting
    // progressive atlas pop-in.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("background", .image, "png", "fake-bytes-1");
    try game.assets.register("ship", .image, "png", "fake-bytes-2");
    // Note: assets stay in `.registered` state — no backend, never reach .ready.

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("debug/peek", emptyLoader);

    _ = game.setScene("debug/peek") catch {};

    // The swap committed despite assets not being .ready.
    try testing.expectEqualStrings("debug/peek", game.getCurrentSceneName().?);
    try testing.expect(game.pendingSceneName() == null);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("background").?.refcount);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("ship").?.refcount);
}

test "Game: pendingSceneName clears after the swap commits" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("background", .image, "png", "fake-bytes");
    {
        const e = game.assets.entries.getPtr("background").?;
        e.state = .ready;
    }

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("instant_loader", emptyLoader);

    _ = game.setScene("instant_loader") catch {};

    try testing.expectEqualStrings("instant_loader", game.getCurrentSceneName().?);
    try testing.expect(game.pendingSceneName() == null);
}

test "Game: setSceneAtomic without initial_state leaves game_state untouched" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    game.registerSceneSimple("plain", emptyLoader);

    game.setState("custom_state");

    try game.setSceneAtomic("plain");

    try testing.expectEqualStrings("custom_state", game.getState());
}

test "Game: slash-named scene preserves original name for lookup" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const emptyLoader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;

    // The assembler flattens "world/intro" to "world_intro" for the Zig ident
    // in SceneAssetManifests, but the registerScene call and the `game.scenes`
    // map key both use the original slash-style name, so game.scenes.get
    // lookup must use the slash form too.
    const intro_assets: []const []const u8 = &.{ "hero_idle", "city_bg" };
    game.registerSceneWithAssets("world/intro", emptyLoader, intro_assets);

    const entry = game.scenes.get("world/intro").?;
    try testing.expectEqual(@as(usize, 2), entry.assets.len);
    try testing.expectEqualStrings("hero_idle", entry.assets[0]);
    try testing.expectEqualStrings("city_bg", entry.assets[1]);
}

// ── game.assets wiring (#454) ──────────────────────────────────

test "Game: assets field is initialized and round-trips cleanly (no worker spawn)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Fresh catalog: no worker thread until the first acquire. Basic
    // query sites must all be safe to hit immediately after init —
    // this is the "no one ever streams anything" degenerate case that
    // proves the field costs nothing.
    const empty: []const []const u8 = &.{};
    try testing.expect(game.assets.allReady(empty));
    try testing.expectEqual(@as(f32, 1.0), game.assets.progress(empty));
    try testing.expect(!game.assets.isReady("missing"));
    try testing.expectEqual(@as(?anyerror, null), game.assets.lastError("missing"));

    // `pump()` is safe to call with nothing queued (the engine tick
    // does NOT pump automatically — scripts do).
    game.assets.pump();
}

test "Game: assets.register + acquire + release exercise full catalog API through the field" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Register a placeholder image asset — no backend injected, so the
    // worker will eventually surface `error.ImageBackendNotInitialized`
    // on the result ring, but that's fine for this smoke test: we're
    // only proving the API surface is reachable through `game.assets`.
    try game.assets.register("background", .image, "png", "fake-bytes");

    const entry = try game.assets.acquire("background");
    try testing.expectEqual(@as(u32, 1), entry.refcount);

    const manifest: []const []const u8 = &.{"background"};
    try testing.expect(!game.assets.allReady(manifest));
    try testing.expectEqual(@as(f32, 0.0), game.assets.progress(manifest));

    game.assets.release("background");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
}

test "Game: assets.register + acquire + pump round-trips to .ready via mock image backend" {
    const image_loader = engine.ImageLoader;
    // Defensive: clear any backend leaked by a previous test in this binary.
    image_loader.clearBackend();

    const Mock = struct {
        var upload_calls: u32 = 0;
        var unload_calls: u32 = 0;
        var next_tex: engine.AssetTexture = 900;

        fn decodeFn(
            file_type: [:0]const u8,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) anyerror!engine.DecodedImage {
            _ = file_type;
            _ = data;
            const pixels = try allocator.alloc(u8, 4);
            @memset(pixels, 0xAA);
            return .{ .pixels = pixels, .width = 1, .height = 1 };
        }

        fn uploadFn(decoded: engine.DecodedImage) anyerror!engine.AssetTexture {
            _ = decoded;
            upload_calls += 1;
            const t = next_tex;
            next_tex += 1;
            return t;
        }

        fn unloadFn(_: engine.AssetTexture) void {
            unload_calls += 1;
        }

        const backend: engine.ImageBackend = .{
            .decode = decodeFn,
            .upload = uploadFn,
            .unload = unloadFn,
        };
    };
    Mock.upload_calls = 0;
    Mock.unload_calls = 0;
    Mock.next_tex = 900;

    image_loader.setBackend(Mock.backend);
    defer image_loader.clearBackend();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("hero", .image, "png", "fake-png-bytes");
    const entry = try game.assets.acquire("hero");
    try testing.expectEqual(@as(u32, 1), entry.refcount);

    // Spin up to 200ms for the worker to publish a decode result, then
    // pump on the main thread. Mirrors the test harness from
    // `src/assets/catalog.zig` so we don't need to duplicate the
    // ring-peeking helper.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        var total: u32 = 0;
        for (&game.assets.results) |*ring| {
            total += ring.head.load(.acquire) -% ring.tail.load(.acquire);
        }
        if (total >= 1) break;
        { var _req: std.c.timespec = .{ .sec = (step_ns / std.time.ns_per_s), .nsec = (step_ns % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    } else {
        return error.WorkerDidNotRespond;
    }

    game.assets.pump();

    try testing.expect(game.assets.isReady("hero"));
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);

    const manifest: []const []const u8 = &.{"hero"};
    try testing.expect(game.assets.allReady(manifest));
    try testing.expectEqual(@as(f32, 1.0), game.assets.progress(manifest));

    // Free the GPU handle explicitly so the mock balances its counters
    // (catalog-driven free on release lands in #446).
    const entry_ptr = game.assets.entries.getPtr("hero").?;
    entry_ptr.loader.free(entry_ptr);
    try testing.expectEqual(@as(u32, 1), Mock.unload_calls);
}

test "Game: hierarchy parent/child" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 100, .y = 100 });
    game.addSprite(parent, .{ .sprite_name = "parent" });

    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.addSprite(child, .{ .sprite_name = "child" });
    game.setParent(child, parent, .{});

    game.tick(0.016);
    game.render();

    try testing.expect(game.hasComponent(child, ParentComponent(u32)));
    game.removeParent(child);
    try testing.expect(!game.hasComponent(child, ParentComponent(u32)));
}

test "Game: quit sets running to false" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isRunning());
    game.quit();
    try testing.expect(!game.isRunning());
}

test "Game: gizmo enable/disable" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isGizmosEnabled());
    game.setGizmosEnabled(false);
    try testing.expect(!game.isGizmosEnabled());
    game.setGizmosEnabled(true);
    try testing.expect(game.isGizmosEnabled());
}

test "Game: generic component access" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const e = game.createEntity();
    game.addComponent(e, Tag{ .label = 42 });

    const tag = game.getComponent(e, Tag);
    try testing.expect(tag != null);
    try testing.expectEqual(42, tag.?.label);

    try testing.expect(game.hasComponent(e, Tag));
    game.removeComponent(e, Tag);
    try testing.expect(!game.hasComponent(e, Tag));
}

test "Game: cascade destroy removes children" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });

    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    try testing.expectEqual(2, game.entityCount());
    game.destroyEntity(parent);
    try testing.expectEqual(0, game.entityCount());
}

// ── Entity liveness guards (#419) ──────────────────────────────

test "Game: destroyed entity is no longer alive" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 1, .y = 2 });
    try testing.expect(game.ecs_backend.entityExists(e));

    game.destroyEntity(e);
    try testing.expect(!game.ecs_backend.entityExists(e));
}

test "Game: read-only ops on destroyed entity return null/default" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const e = game.createEntity();
    game.addComponent(e, Tag{ .label = 42 });
    game.setPosition(e, .{ .x = 5, .y = 10 });
    game.destroyEntity(e);

    // getComponent returns null — safe, no panic
    try testing.expectEqual(@as(?*Tag, null), game.getComponent(e, Tag));
    // hasComponent returns false — safe, no panic
    try testing.expect(!game.hasComponent(e, Tag));
    // getPosition returns default — safe, no panic
    const pos = game.getPosition(e);
    try testing.expectEqual(0.0, pos.x);
    try testing.expectEqual(0.0, pos.y);
}

// ── Tombstone tracking (#420) ──────────────────────────────────

test "Game: tombstone records frame number" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.frame_number = 42;
    game.destroyEntity(e);

    const tomb = game.findTombstone(e);
    try testing.expect(tomb != null);
    try testing.expectEqual(42, tomb.?.frame);
    try testing.expectEqual(e, tomb.?.entity);
}

test "Game: tombstone ring wraps around" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Fill the ring buffer beyond capacity
    var first_entity: Game.EntityType = undefined;
    for (0..Game.tombstone_size + 10) |i| {
        const e = game.createEntity();
        if (i == 0) first_entity = e;
        game.frame_number = @intCast(i);
        game.destroyEntity(e);
    }

    // First entity should have been evicted from the ring
    try testing.expectEqual(@as(?Game.TombstoneEntry, null), game.findTombstone(first_entity));

    // Recent entities should still be in the ring
    const last = game.createEntity();
    game.frame_number = 999;
    game.destroyEntity(last);
    const tomb = game.findTombstone(last);
    try testing.expect(tomb != null);
    try testing.expectEqual(999, tomb.?.frame);
}

test "Game: cascade destroy records tombstones for parent and children" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    game.frame_number = 100;
    game.destroyEntity(parent);

    // Both parent and child should have tombstones
    const parent_tomb = game.findTombstone(parent);
    try testing.expect(parent_tomb != null);
    try testing.expectEqual(100, parent_tomb.?.frame);

    const child_tomb = game.findTombstone(child);
    try testing.expect(child_tomb != null);
    try testing.expectEqual(100, child_tomb.?.frame);
}
