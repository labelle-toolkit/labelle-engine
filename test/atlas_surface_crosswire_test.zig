//! Atlas ↔ texture binding integrity across scene swaps and GPU surface
//! loss (labelle-engine#821, #822, #820).
//!
//! On Android a TERM_WINDOW destroys every GPU texture; the engine
//! forgets its handles (`surfaceLost`), re-decodes and re-uploads on
//! INIT_WINDOW (`surfaceRestored`), and the per-tick bridge re-binds each
//! `RuntimeAtlas.texture_id` to the fresh handle. A scene swap meanwhile
//! releases the outgoing manifest, whose textures are freed and whose
//! catalog slots become recyclable by the next scene's uploads — in
//! decode-completion order, i.e. in a DIFFERENT atlas→slot assignment
//! every time. #821 reported rooms drawing hull/character slices after a
//! quit-to-menu → New Game with a surface cycle in the mix.
//!
//! These tests drive the real `Game` (catalog + worker pool + atlas
//! manager + scene gate) against an image backend that models the
//! assembler-emitted `ImageBackendAdapter` faithfully:
//!
//!   * handles are `CATALOG_ID_BASE + slot`, slot = lowest free index,
//!     freed on `unload` — so a reload hands atlas A's old slot to atlas B;
//!   * each decoded image carries its ATLAS TAG in its first pixel byte,
//!     so the backend can record which atlas's pixels each slot holds;
//!   * a surface loss bumps an epoch — every texture uploaded before it is
//!     dead, exactly like bgfx after `shutdown`.
//!
//! The invariant asserted after every step: every atlas's `texture_id`
//! names a slot that (a) holds THAT atlas's image and (b) was uploaded
//! AFTER the last surface loss. (a) failing is the cross-wire; (b) failing
//! is a stale handle that, on a real backend, aliases whichever texture
//! recycled its backend id.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

// ── Mock renderer (same shape as asset_streaming_shim_test.zig's) ──

fn MockRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            source_rect: struct {
                x: f32 = 0,
                y: f32 = 0,
                width: f32 = 0,
                height: f32 = 0,
                display_width: f32 = 0,
                display_height: f32 = 0,
            } = .{},
            texture: enum(u32) { invalid = 0, _ } = .invalid,
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const TextureInfo = struct { width: f32, height: f32 };

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }

        // Flips the atlas shim's `has_load_from_memory` gate so
        // `registerAtlasFromMemory` exists on the Game type. Not reached
        // on the catalog path.
        pub fn loadTextureFromMemory(_: *Self, _: [:0]const u8, _: []const u8) !core.TextureId {
            return @enumFromInt(77);
        }
        pub fn getTextureInfo(_: *const Self, _: core.TextureId) ?TextureInfo {
            return null;
        }
    };
}

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const TestGame = engine.GameConfig(
    MockRenderer(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void, // hooks
    core.StubLogSink,
    EmptyComponents,
    &.{}, // gizmo categories
    void, // game events
);

fn emptyLoader(_: *TestGame) anyerror!void {}

// ── Adapter model ──
//
// Mirrors labelle-assembler's generated `ImageBackendAdapter`: a
// fixed slot table, lowest-free-index allocation, `handle = BASE + slot`,
// `unload` frees the slot. Plus the two things the real adapter cannot
// tell us but a test must: WHICH atlas's pixels a slot holds (the tag
// byte the decoder copies out of the raw bytes) and in which surface
// EPOCH the upload happened.

const Adapter = struct {
    const MAX_SLOTS = 64;
    const BASE: u32 = 1 << 24;

    // ── Threading ──
    //
    // `decode` runs on the catalog's THREE worker threads; `upload` /
    // `unload` run on the main thread (from `pump` / `release`), and so
    // does every assertion. State the workers touch is therefore atomic;
    // the slot table below stays plain because it is main-thread-confined
    // (making it atomic would only hide that fact).

    /// Which atlas's pixels each slot holds, and the surface epoch it was
    /// uploaded in. Written by `upload`/`unload`, read by the assertions —
    /// all on the main thread.
    var slot_tag: [MAX_SLOTS]?u8 = [_]?u8{null} ** MAX_SLOTS;
    var slot_epoch: [MAX_SLOTS]u32 = [_]u32{0} ** MAX_SLOTS;
    var epoch: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;

    /// Bumped from every worker thread, so atomic.
    var decode_calls: std.atomic.Value(u32) = .init(0);
    /// The "make this atlas's decode slow" knob: the test writes it from
    /// the main thread while workers are running, and every worker reads
    /// it on each decode. Atomic for that reason. `no_slow_tag` is the
    /// "unset" sentinel — the tags are image bytes, so a value outside
    /// `u8` can never collide with one.
    const no_slow_tag: u16 = 0x100;
    var slow_tag: std.atomic.Value(u16) = .init(no_slow_tag);
    var slow_ns: std.atomic.Value(u64) = .init(0);

    fn reset() void {
        slot_tag = [_]?u8{null} ** MAX_SLOTS;
        slot_epoch = [_]u32{0} ** MAX_SLOTS;
        epoch = 0;
        upload_calls = 0;
        unload_calls = 0;
        decode_calls.store(0, .monotonic);
        clearSlow();
    }

    /// Slow every decode of `tag` down by `ns`, so "atlas X is still in
    /// flight when the surface goes" is deterministic instead of a race.
    fn setSlow(tag: u8, ns: u64) void {
        slow_ns.store(ns, .monotonic);
        slow_tag.store(tag, .monotonic);
    }

    fn clearSlow() void {
        slow_tag.store(no_slow_tag, .monotonic);
        slow_ns.store(0, .monotonic);
    }

    /// The GPU context died: every texture uploaded so far is gone. The
    /// real adapter never learns this (the catalog drops its handles
    /// without calling `unload`), so the slots stay occupied — just as
    /// they do on-device.
    fn surfaceLost() void {
        epoch += 1;
    }

    fn decodeFn(_: [:0]const u8, data: []const u8, allocator: std.mem.Allocator) anyerror!engine.DecodedImage {
        _ = decode_calls.fetchAdd(1, .monotonic);
        const tag = slow_tag.load(.monotonic);
        if (tag != no_slow_tag and data.len > 0 and data[0] == @as(u8, @intCast(tag))) {
            sleepNs(slow_ns.load(.monotonic));
        }
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0);
        // First pixel byte = atlas tag = first byte of the raw image.
        pixels[0] = if (data.len > 0) data[0] else 0;
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(decoded: engine.DecodedImage) anyerror!engine.AssetTexture {
        upload_calls += 1;
        var handle: u32 = MAX_SLOTS;
        for (slot_tag, 0..) |s, i| {
            if (s == null) {
                handle = @intCast(i);
                break;
            }
        }
        if (handle == MAX_SLOTS) return error.ImageSlotsExhausted;
        slot_tag[handle] = decoded.pixels[0];
        slot_epoch[handle] = epoch;
        return BASE + handle;
    }

    fn unloadFn(texture: engine.AssetTexture) void {
        unload_calls += 1;
        if (texture < BASE) return;
        const idx = texture - BASE;
        if (idx >= MAX_SLOTS) return;
        slot_tag[idx] = null;
    }

    const backend: engine.ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) req = rem;
}

// ── Fixture: atlases + scenes shaped like flying-platform's ──
//
// Every atlas is registered LAZILY (`registerAtlasFromMemory`, as the
// assembler emits for the Android build) so its lifetime is entirely
// manifest-driven: acquired by the scene gate, released by the swap.
// `menu` shares `bg` with `main`; `a`/`b`/`c` are exclusive to `main`
// and therefore freed (slots recycled) on every quit-to-menu.

const atlas_json: []const u8 =
    \\{ "frames": { "sprite_0": { "frame": { "x": 0, "y": 0, "w": 1, "h": 1 } } },
    \\  "meta": { "size": { "w": 1, "h": 1 } } }
;
const file_type: [:0]const u8 = ".png";

const AtlasDef = struct { name: []const u8, bytes: []const u8 };
// Tag byte = first byte of `bytes`.
const atlases = [_]AtlasDef{
    .{ .name = "a", .bytes = "A-png" },
    .{ .name = "b", .bytes = "B-png" },
    .{ .name = "c", .bytes = "C-png" },
    .{ .name = "bg", .bytes = "G-png" },
};
const main_manifest: []const []const u8 = &.{ "a", "b", "c", "bg" };
const menu_manifest: []const []const u8 = &.{"bg"};

fn tagOf(name: []const u8) u8 {
    for (atlases) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.bytes[0];
    }
    unreachable;
}

fn setup(game: *TestGame) !void {
    for (atlases) |d| try game.registerAtlasFromMemory(d.name, atlas_json, d.bytes, file_type);
    game.registerSceneWithAssets("menu", emptyLoader, menu_manifest);
    game.registerSceneWithAssets("main", emptyLoader, main_manifest);
}

/// One game frame, the way the backend's loop produces them.
fn frame(game: *TestGame) void {
    game.tick(1.0 / 60.0);
    // Let the worker threads make progress between frames.
    sleepNs(200 * std.time.ns_per_us);
}

/// Tick until the queued scene change commits (the gate re-polls every
/// frame, exactly like `queueSceneChangeAtomic` in a shipped game).
fn driveSceneChange(game: *TestGame) !void {
    var frames: usize = 0;
    while (game.pending_scene_change != null) : (frames += 1) {
        if (frames > 5000) return error.SceneChangeDidNotCommit;
        frame(game);
    }
}

/// Tick until every catalog entry the current scene draws from is
/// `.ready` and bound — the steady state a player sees.
fn driveUntilSettled(game: *TestGame, names: []const []const u8) !void {
    var frames: usize = 0;
    while (frames < 5000) : (frames += 1) {
        var settled = true;
        for (names) |n| {
            if (!game.assets.isReady(n)) settled = false;
            const atlas = game.atlas_manager.getAtlas(n) orelse return error.AtlasMissing;
            if (!atlas.isLoaded()) settled = false;
        }
        if (settled) return;
        frame(game);
    }
    return error.DidNotSettle;
}

/// THE invariant. For each atlas: bound, to a slot holding ITS pixels,
/// uploaded in the CURRENT surface epoch, and agreeing with the catalog.
fn expectBindingsFresh(game: *TestGame, names: []const []const u8) !void {
    for (names) |n| {
        const atlas = game.atlas_manager.getAtlas(n) orelse return error.AtlasMissing;
        errdefer std.debug.print("atlas '{s}': texture_id={d} pending={} epoch={d}\n", .{ n, atlas.texture_id, atlas.pending != null, Adapter.epoch });
        try testing.expect(atlas.isLoaded());
        const tid = atlas.texture_id;
        try testing.expect(tid >= Adapter.BASE);
        const idx = tid - Adapter.BASE;
        try testing.expect(idx < Adapter.MAX_SLOTS);
        // (a) the slot holds this atlas's image — not another atlas's
        try testing.expectEqual(@as(?u8, tagOf(n)), Adapter.slot_tag[idx]);
        // (b) it was uploaded after the last surface loss — not a dead
        //     handle that would alias a recycled backend id
        try testing.expectEqual(Adapter.epoch, Adapter.slot_epoch[idx]);
        // (c) the catalog's own record agrees with the binding
        const entry = game.assets.entries.getPtr(n) orelse return error.EntryMissing;
        try testing.expectEqual(engine.AssetState.ready, entry.state);
        try testing.expectEqual(tid, entry.resource.?.image);
    }
}

/// Backend TERM_WINDOW → INIT_WINDOW, as labelle-bgfx's android_app
/// drives them: `surfaceLost` while handles are alive, the context dies,
/// `surfaceRestored` on the new context.
fn surfaceCycle(game: *TestGame) void {
    game.surfaceLost();
    Adapter.surfaceLost();
    game.surfaceRestored();
}

// ── Tests ──

test "cold boot → New Game → surface cycle: every atlas rebinds to its own fresh texture" {
    Adapter.reset();
    engine.ImageLoader.setBackend(Adapter.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try setup(&game);

    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);
    game.queueSceneChangeAtomic("main");
    try driveSceneChange(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);

    surfaceCycle(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);
}

test "#821 timeline: surface cycle → quit to menu → New Game (slots recycled) → surface cycle" {
    Adapter.reset();
    engine.ImageLoader.setBackend(Adapter.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try setup(&game);

    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);
    game.queueSceneChangeAtomic("main");
    try driveSceneChange(&game);
    try driveUntilSettled(&game, main_manifest);

    // Background/resume once while playing — verified correct on-device.
    surfaceCycle(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);

    // Quit to menu: a/b/c drop to refcount 0, their textures are freed
    // and their slots become recyclable. `bg` stays shared.
    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);
    try expectBindingsFresh(&game, menu_manifest);

    // New Game: a/b/c re-decode and land in the freed slots in
    // completion order — a different atlas→slot assignment than before.
    game.queueSceneChangeAtomic("main");
    try driveSceneChange(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);

    // The second surface cycle of the report, on top of the reload.
    surfaceCycle(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);
}

test "#821: surface cycle lands while the New Game load is in flight (partially ready manifest)" {
    Adapter.reset();
    engine.ImageLoader.setBackend(Adapter.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try setup(&game);

    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);
    game.queueSceneChangeAtomic("main");
    try driveSceneChange(&game);
    try driveUntilSettled(&game, main_manifest);
    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);

    // Make `c` slow so, by the time we pull the surface, `a` and `b`
    // have re-uploaded and (per the per-tick bridge) may be bound while
    // `c` is still decoding — the "uploads in flight / partially ready"
    // window of the report.
    Adapter.setSlow(tagOf("c"), 40 * std.time.ns_per_ms);
    game.queueSceneChangeAtomic("main");
    var frames: usize = 0;
    while (frames < 200) : (frames += 1) {
        frame(&game);
        if (game.assets.isReady("a") and game.assets.isReady("b")) break;
    }
    try testing.expect(game.assets.isReady("a") and game.assets.isReady("b"));
    try testing.expect(!game.assets.isReady("c"));
    try testing.expect(game.pending_scene_change != null); // gate still deferring

    surfaceCycle(&game);
    Adapter.clearSlow();

    try driveSceneChange(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);
}

test "#821: surface cycle sweep — pulled at every frame offset of a New Game reload" {
    Adapter.reset();
    engine.ImageLoader.setBackend(Adapter.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try setup(&game);

    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);

    // Each iteration: quit to menu (frees a/b/c), New Game, tick `k`
    // frames into the reload, pull the surface, finish, verify. Sweeping
    // `k` across a modest decode latency hits "nothing landed", "some
    // landed", and "all landed but not yet committed".
    Adapter.setSlow(tagOf("b"), 3 * std.time.ns_per_ms);
    var k: usize = 0;
    while (k < 12) : (k += 1) {
        game.queueSceneChangeAtomic("main");
        var i: usize = 0;
        while (i < k) : (i += 1) frame(&game);
        surfaceCycle(&game);
        try driveSceneChange(&game);
        try driveUntilSettled(&game, main_manifest);
        try expectBindingsFresh(&game, main_manifest);

        game.queueSceneChangeAtomic("menu");
        try driveSceneChange(&game);
        try expectBindingsFresh(&game, menu_manifest);
    }
}

test "load path: a second menu→Load recycles the first load's slots — atlases must rebind" {
    // `loadGameState` pins the SAVED scene's manifest through
    // `armPostLoadRenderGate` (#638) and drops the previous load's pin on
    // the next load (`releaseLoadAcquired`). A player who loads save A
    // from the menu, quits to the menu, and loads save B therefore frees
    // a/b/c to refcount 0 (textures destroyed, slots recyclable) and
    // immediately re-acquires them — the same recycle #822 fixed for the
    // scene-swap path, reached through the load path instead.
    Adapter.reset();
    engine.ImageLoader.setBackend(Adapter.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try setup(&game);

    game.queueSceneChangeAtomic("menu");
    try driveSceneChange(&game);

    // Load A from the menu: the saved scene is `main`, the active scene
    // stays `menu` (a load never swaps scenes).
    game.armPostLoadRenderGate("main");
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);

    // Load B from the menu: releases A's pin (a/b/c → 0 → freed), then
    // re-acquires the same manifest; uploads land in the freed slots in
    // completion order.
    game.armPostLoadRenderGate("main");
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);

    // ...and a surface cycle on top of that.
    surfaceCycle(&game);
    try driveUntilSettled(&game, main_manifest);
    try expectBindingsFresh(&game, main_manifest);
}

// ── TextureManager unit tests: the identity-keyed rebind itself ──

const TextureManager = engine.atlas_mod.TextureManager;

test "markPendingLoaded: rebinding to the same handle is the routine no-op (AtlasNotPending, no version bump)" {
    var tm = TextureManager.init(testing.allocator);
    defer tm.deinit();
    try tm.registerPendingAtlas("a", atlas_json, "A-png", file_type);

    try tm.markPendingLoaded("a", 100, null);
    const v = tm.version;
    try testing.expectError(error.AtlasNotPending, tm.markPendingLoaded("a", 100, null));
    try testing.expectEqual(v, tm.version);
    try testing.expectEqual(@as(u32, 100), tm.getAtlas("a").?.texture_id);
}

test "markPendingLoaded: a loaded catalog atlas handed a DIFFERENT handle rebinds (engine#821)" {
    var tm = TextureManager.init(testing.allocator);
    defer tm.deinit();
    try tm.registerPendingAtlas("a", atlas_json, "A-png", file_type);
    try tm.markPendingLoaded("a", 100, null);
    const v = tm.version;

    // The catalog freed slot 100 and re-uploaded `a` into slot 101
    // without anyone re-arming `pending` — the binding must follow the
    // asset, not the latch.
    try tm.markPendingLoaded("a", 101, null);
    try testing.expectEqual(@as(u32, 101), tm.getAtlas("a").?.texture_id);
    try testing.expect(tm.getAtlas("a").?.isLoaded());
    // Sprite caches key on `version`; a rebind must invalidate them.
    try testing.expect(tm.version > v);
}

test "markPendingLoaded: an eager (renderer-owned) atlas never rebinds" {
    var tm = TextureManager.init(testing.allocator);
    defer tm.deinit();
    // `loadAtlasComptime` binds a renderer texture the catalog does not
    // manage: `loaded_image == null`, and no catalog handle may ever
    // overwrite it.
    try tm.loadAtlasComptime("eager", &.{}, 7);
    try testing.expectError(error.AtlasNotPending, tm.markPendingLoaded("eager", 8, null));
    try testing.expectEqual(@as(u32, 7), tm.getAtlas("eager").?.texture_id);
}

test "invalidateAtlasBinding: idempotent on an already-pending atlas (no per-tick version churn)" {
    var tm = TextureManager.init(testing.allocator);
    defer tm.deinit();
    try tm.registerPendingAtlas("a", atlas_json, "A-png", file_type);
    try tm.markPendingLoaded("a", 100, null);

    tm.invalidateAtlasBinding("a");
    try testing.expect(!tm.getAtlas("a").?.isLoaded());
    try testing.expectEqual(@as(u32, 0), tm.getAtlas("a").?.texture_id);
    const v = tm.version;
    // The per-tick bridge calls this for every not-ready image entry;
    // a second call must not bump `version` (that would flush the
    // sprite cache every frame while an atlas is in flight).
    tm.invalidateAtlasBinding("a");
    try testing.expectEqual(v, tm.version);
}
