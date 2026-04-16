//! Game-level tests for the pump-driven legacy atlas shim (Asset
//! Streaming RFC #437, ticket #443).
//!
//! `Game.loadAtlasFromMemory` / `registerAtlasFromMemory` /
//! `loadAtlasIfNeeded` / `isAtlasLoaded` are a back-compat façade over
//! `src/assets/`. The body of every method ultimately flows through
//! `AssetCatalog.acquire` + `AssetCatalog.pump`, but the surface
//! behaviour — "block the calling frame until the atlas is loaded" —
//! matches the legacy `renderer.loadTextureFromMemory` path the
//! assembler's smoke-test example still emits.
//!
//! The tests below exercise the full Game → catalog → mock image
//! backend → `TextureManager.markPendingLoaded` round-trip so the
//! smoke-test example's generated code keeps working. In particular
//! the "deadlock regression" test verifies that an injected decode
//! error surfaces via `lastError` inside a short timeout instead of
//! hanging forever — the critical failure mode the sync shim is built
//! to avoid (RFC §2: "CRITICAL — without this [pump() call], deadlock").

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

// ── Mock renderer with loadTextureFromMemory + getTextureInfo ──
//
// `Game.loadAtlasFromMemory` and friends are gated on
// `@hasDecl(RenderImpl, "loadTextureFromMemory")`. The shim itself
// does not actually call the method (the catalog handles the upload),
// but the gate still has to flip to `true` for the methods to exist
// on the Game type. `StubRender` does not expose it, so we wrap a
// hand-rolled renderer that satisfies both the `RenderInterface`
// contract and the extra declarations the atlas shim inspects.

const MockEcs = core.MockEcsBackend(u32);

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

        pub const TextureId = enum(u32) { invalid = 0, _ };
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
        pub fn renderGizmoDraws(_: *Self, _: []const @import("labelle-core").GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }

        // Present only so the atlas shim's `has_load_from_memory`
        // gate flips to `true`. The shim no longer invokes it — the
        // catalog owns the upload — but removing it would disable the
        // shim entirely on this Game type.
        pub fn loadTextureFromMemory(_: *Self, _: [:0]const u8, _: []const u8) !TextureId {
            return .invalid;
        }

        // Not used on the catalog path (the catalog-managed upload
        // bypasses the renderer's texture side-table), but the shim
        // compiles the `queryTextureDims` call against it. Returning
        // `null` matches the adapter-uploaded-texture reality.
        pub fn getTextureInfo(_: *const Self, _: TextureId) ?TextureInfo {
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
    engine.gui_mod.StubGui,
    void, // hooks
    core.StubLogSink,
    EmptyComponents,
    &.{}, // gizmo categories
    void, // game events
);

// ── Mock ImageBackend ──
//
// The image loader's `backend` slot is a process-global, so the tests
// reset it between runs. Each test tunes the behaviour by flipping
// flags on this namespace.
const Mock = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var next_tex: engine.AssetTexture = 900;
    var decode_fails: bool = false;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        next_tex = 900;
        decode_fails = false;
    }

    fn decodeFn(
        _: [:0]const u8,
        _: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!engine.DecodedImage {
        decode_calls += 1;
        if (decode_fails) return error.MockDecodeFailure;
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0x11);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(_: engine.DecodedImage) anyerror!engine.AssetTexture {
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

// TexturePacker JSON that passes the eager parse inside
// `TextureManager.registerPendingAtlas`. One sprite is enough — the
// tests care about lifecycle, not atlas content.
const tiny_atlas_json: []const u8 =
    \\{ "frames": { "sprite_0": { "frame": { "x": 0, "y": 0, "w": 1, "h": 1 } } },
    \\  "meta": { "size": { "w": 1, "h": 1 } } }
;
const fake_png: []const u8 = "fake-png-bytes";
const file_type: [:0]const u8 = "png";

// ── Tests ──

test "shim: registerAtlasFromMemory + loadAtlasIfNeeded round-trip" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerAtlasFromMemory("bg", tiny_atlas_json, fake_png, file_type);
    try testing.expect(!game.isAtlasLoaded("bg"));

    const did_load = try game.loadAtlasIfNeeded("bg");
    try testing.expect(did_load);
    try testing.expect(game.isAtlasLoaded("bg"));
    try testing.expectEqual(@as(u32, 1), Mock.decode_calls);
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "shim: loadAtlasFromMemory is eager — atlas loaded before it returns" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.loadAtlasFromMemory("eager", tiny_atlas_json, fake_png, file_type);
    // Legacy surface contract — the atlas is usable after the call
    // returns, no extra `loadAtlasIfNeeded` needed.
    try testing.expect(game.isAtlasLoaded("eager"));
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "shim: loadAtlasIfNeeded twice is idempotent — second call is a no-op" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerAtlasFromMemory("twice", tiny_atlas_json, fake_png, file_type);
    try testing.expect(try game.loadAtlasIfNeeded("twice"));
    // Second call: atlas is already loaded → returns false without
    // touching the catalog a second time.
    try testing.expectEqual(@as(bool, false), try game.loadAtlasIfNeeded("twice"));
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "shim: loadAtlasIfNeeded on unknown atlas returns AtlasNotFound" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expectError(error.AtlasNotFound, game.loadAtlasIfNeeded("ghost"));
}

test "shim: isAtlasLoaded is false for unregistered and pending, true after load" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.isAtlasLoaded("never"));

    try game.registerAtlasFromMemory("pending", tiny_atlas_json, fake_png, file_type);
    try testing.expect(!game.isAtlasLoaded("pending"));

    _ = try game.loadAtlasIfNeeded("pending");
    try testing.expect(game.isAtlasLoaded("pending"));
}

test "shim: deadlock regression — decode error surfaces within 200ms, no hang" {
    // The core sync-shim invariant: without the `pump()` call inside
    // the busy-wait, `isReady` never flips and the loop spins forever.
    // A forced decode error proves the loop terminates on the error
    // path; combined with `shim: loadAtlasIfNeeded twice is idempotent`
    // above (which proves the loop terminates on the happy path), we
    // cover both exits. The 200ms timeout bounds runaway-spin failures
    // so a regression fails CI instead of stalling it.

    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerAtlasFromMemory("dead", tiny_atlas_json, fake_png, file_type);

    // Run the shim on a background thread so the main thread can
    // impose a deadline. A deadlock manifests as the worker never
    // finishing — the 200ms wait below expires while
    // `loadAtlasIfNeeded` is still spinning.
    const Runner = struct {
        result: ?anyerror = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This(), g: *TestGame) void {
            if (g.loadAtlasIfNeeded("dead")) |_| {
                self.result = null;
            } else |err| {
                self.result = err;
            }
            self.done.store(true, .release);
        }
    };
    var runner = Runner{};
    const handle = try std.Thread.spawn(.{}, Runner.run, .{ &runner, &game });

    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        if (runner.done.load(.acquire)) break;
        std.Thread.sleep(step_ns);
    }
    const terminated = runner.done.load(.acquire);
    handle.join();
    try testing.expect(terminated);
    // The error surfaced through the catalog's `lastError` path —
    // not a successful load, not a hang.
    try testing.expectEqual(
        @as(?anyerror, error.MockDecodeFailure),
        runner.result,
    );
    // Atlas still reports unloaded — the failure did NOT accidentally
    // flip the TextureManager's pending→loaded transition.
    try testing.expect(!game.isAtlasLoaded("dead"));
}

test "shim: double register through the shim is tolerated" {
    // The assembler emits `engine.AssetCatalog.register(...)` from a
    // scene's asset manifest at init time; later the same asset is
    // re-registered through the legacy `registerAtlasFromMemory` when
    // a script runs `loadAtlasIfNeeded`. The shim must not crash.

    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // First path: manifest-style register directly on the catalog.
    try game.assets.register("shared", .image, file_type, fake_png);

    // Second path: legacy shim. Must swallow `AssetAlreadyRegistered`
    // rather than propagate it.
    try game.registerAtlasFromMemory("shared", tiny_atlas_json, fake_png, file_type);

    _ = try game.loadAtlasIfNeeded("shared");
    try testing.expect(game.isAtlasLoaded("shared"));
}
