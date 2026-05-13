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

test "shim: acquire refcount is released when decode fails" {
    // Regression for missing `errdefer release` in `loadAtlasIfNeededImpl`.
    // Before the fix, a decode failure left the catalog refcount at 1
    // indefinitely: the atlas stayed "acquired" even though it would
    // never load. The test verifies the refcount is back to 0 after the
    // error so the catalog can be torn down cleanly (testing.allocator
    // catches any leak from a still-pinned entry).

    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerAtlasFromMemory("err_release", tiny_atlas_json, fake_png, file_type);
    try testing.expectError(error.MockDecodeFailure, game.loadAtlasIfNeeded("err_release"));

    // After the error the catalog entry must not be pinned: refcount
    // should be back at 0. Accessing `.entries` directly is
    // intentional — there is no higher-level API for this check.
    const entry = game.assets.entries.get("err_release").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);
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

// ── Audio shim (Phase 4, #447) ──
//
// `registerSoundFromMemory` / `loadSoundFromMemory` / `loadSoundIfNeeded`
// are the audio siblings of the atlas shim methods above. The mock
// backend below mirrors `Mock` for images: process-global slot, reset
// between tests, counters for decode / upload / unload.

const MockAudio = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    const sentinel: engine.SoundId = .{ .index = 7, .generation = 1 };

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
    }

    fn decodeFn(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) anyerror!engine.DecodedAudio {
        decode_calls += 1;
        // 4 frames stereo, recognisable fill so a sloppy backend gets
        // caught by `last_uploaded` assertions in the loader test.
        const samples = try allocator.alloc(i16, 8);
        @memset(samples, 0x1234);
        return .{ .samples = samples, .sample_rate = 44100, .channels = 2 };
    }

    fn uploadFn(_: engine.DecodedAudio) anyerror!engine.SoundId {
        upload_calls += 1;
        return sentinel;
    }

    fn unloadFn(_: engine.SoundId) void {
        unload_calls += 1;
    }

    const backend: engine.AudioBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

const fake_wav: []const u8 = "fake-wav-bytes";
const audio_file_type: [:0]const u8 = "wav";

test "audio shim: registerSoundFromMemory + loadSoundIfNeeded round-trip" {
    MockAudio.reset();
    engine.AudioLoader.setBackend(MockAudio.backend);
    defer engine.AudioLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerSoundFromMemory("sfx", audio_file_type, fake_wav);
    try testing.expect(!game.assets.isReady("sfx"));

    const did_load = try game.loadSoundIfNeeded("sfx");
    try testing.expect(did_load);
    try testing.expect(game.assets.isReady("sfx"));
    try testing.expectEqual(@as(u32, 1), MockAudio.decode_calls);
    try testing.expectEqual(@as(u32, 1), MockAudio.upload_calls);
}

test "audio shim: loadSoundFromMemory is eager — ready before it returns" {
    MockAudio.reset();
    engine.AudioLoader.setBackend(MockAudio.backend);
    defer engine.AudioLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.loadSoundFromMemory("eager_sfx", audio_file_type, fake_wav);
    try testing.expect(game.assets.isReady("eager_sfx"));
}

test "audio shim: loadSoundIfNeeded twice is idempotent" {
    MockAudio.reset();
    engine.AudioLoader.setBackend(MockAudio.backend);
    defer engine.AudioLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerSoundFromMemory("twice", audio_file_type, fake_wav);
    const first = try game.loadSoundIfNeeded("twice");
    const second = try game.loadSoundIfNeeded("twice");

    try testing.expect(first);
    try testing.expect(!second);
    try testing.expectEqual(@as(u32, 1), MockAudio.decode_calls);
    try testing.expectEqual(@as(u32, 1), MockAudio.upload_calls);
}

test "audio shim: double register through the shim is tolerated" {
    MockAudio.reset();
    engine.AudioLoader.setBackend(MockAudio.backend);
    defer engine.AudioLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Manifest-style direct register, then shim register — must not
    // propagate `AssetAlreadyRegistered`.
    try game.assets.register("shared_sfx", .audio, audio_file_type, fake_wav);
    try game.registerSoundFromMemory("shared_sfx", audio_file_type, fake_wav);
    _ = try game.loadSoundIfNeeded("shared_sfx");
    try testing.expect(game.assets.isReady("shared_sfx"));
}

// ── Font shim (Phase 4, #448) ──
//
// `registerFontFromMemory` / `loadFontFromMemory` / `loadFontIfNeeded`.
// The font loader is the only loader that takes decode-time params
// (`FontBakeParams`); the shim borrows a pointer that must outlive
// the catalog entry.

const MockFont = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var last_params_pixel_height: f32 = 0;
    const sentinel: engine.FontId = .{ .index = 9, .generation = 1 };

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        last_params_pixel_height = 0;
    }

    fn decodeFn(_: [:0]const u8, _: []const u8, params: engine.FontBakeParams, allocator: std.mem.Allocator) anyerror!engine.DecodedFont {
        decode_calls += 1;
        // Capture the params the loader unmarshalled from
        // `WorkRequest.params` so tests can assert the shim's
        // pointer plumbing through `registerFont`.
        last_params_pixel_height = params.pixel_height;
        // 1×1 alpha atlas, single ASCII space glyph — minimum viable
        // payload that exercises the full slice-ownership contract.
        const bitmap = try allocator.alloc(u8, 1);
        bitmap[0] = 0xFF;
        const glyphs = try allocator.alloc(engine.Glyph, 1);
        glyphs[0] = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .xoff = 0, .yoff = 0, .advance = 8 };
        const idx = try allocator.alloc(engine.CodepointEntry, 1);
        idx[0] = .{ .codepoint = 0x20, .glyph_index = 0 };
        const kern = try allocator.alloc(engine.KernPair, 0);
        return .{
            .bitmap = bitmap,
            .width = 1,
            .height = 1,
            .glyphs = glyphs,
            .codepoint_index = idx,
            .ascent = 12,
            .descent = -4,
            .line_gap = 0,
            .line_height = 16,
            .kerning = kern,
        };
    }

    fn uploadFn(_: engine.DecodedFont) anyerror!engine.FontId {
        upload_calls += 1;
        return sentinel;
    }

    fn unloadFn(_: engine.FontId) void {
        unload_calls += 1;
    }

    const backend: engine.FontBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

const fake_ttf: []const u8 = "fake-ttf-bytes";
const font_file_type: [:0]const u8 = "ttf";

test "font shim: registerFontFromMemory + loadFontIfNeeded round-trip" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.registerFontFromMemory("ui", font_file_type, fake_ttf, &params);
    try testing.expect(!game.assets.isReady("ui"));

    const did_load = try game.loadFontIfNeeded("ui");
    try testing.expect(did_load);
    try testing.expect(game.assets.isReady("ui"));
    try testing.expectEqual(@as(u32, 1), MockFont.decode_calls);
    try testing.expectEqual(@as(u32, 1), MockFont.upload_calls);
    // The shim must have routed `params` through `WorkRequest.params`
    // so the loader's `@ptrCast(@alignCast(...))` casts back to the
    // exact value we passed in.
    try testing.expectEqual(@as(f32, 24), MockFont.last_params_pixel_height);
}

test "font shim: loadFontFromMemory is eager — ready before it returns" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 16 };
    try game.loadFontFromMemory("eager_font", font_file_type, fake_ttf, &params);
    try testing.expect(game.assets.isReady("eager_font"));
}

test "font shim: distinct registrations with different params produce distinct entries" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const small: engine.FontBakeParams = .{ .pixel_height = 12 };
    const large: engine.FontBakeParams = .{ .pixel_height = 48 };
    try game.registerFontFromMemory("font_small", font_file_type, fake_ttf, &small);
    try game.registerFontFromMemory("font_large", font_file_type, fake_ttf, &large);

    _ = try game.loadFontIfNeeded("font_small");
    _ = try game.loadFontIfNeeded("font_large");

    try testing.expect(game.assets.isReady("font_small"));
    try testing.expect(game.assets.isReady("font_large"));
    try testing.expectEqual(@as(u32, 2), MockFont.decode_calls);
    try testing.expectEqual(@as(u32, 2), MockFont.upload_calls);
}
