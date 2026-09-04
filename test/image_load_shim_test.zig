//! Game-level tests for the standalone-image load shims (issue #831).
//!
//! `Game.registerImageFromMemory` / `loadImageFromMemory` /
//! `loadImageIfNeeded` are the `.image` counterpart to the atlas, sound
//! and font pairs. The property they exist for is FIRST-FRAME READINESS:
//! every other resource kind honours `lazy = false` by loading blocking
//! at init, while an eager `.image` used to only `acquire` — starting a
//! worker decode that the per-tick `pump()` finishes some frames later,
//! so an `Image` entity could miss the first frame it was supposed to be
//! visible on.
//!
//! The tests below therefore assert the *contrast* explicitly: after
//! `assets.register` + `assets.acquire` (the pre-#831 eager emission) the
//! asset is NOT ready and carries no texture handle; after
//! `loadImageFromMemory` it is ready and its handle is readable from
//! `entry.resource.?.image` — the exact field the `Image` render seam
//! reads (see `src/image_component.zig` and
//! `bridgeImageAssetsToAtlasManager` in `src/game/scene_mixin.zig`) —
//! with no tick, no pump and no frame in between.
//!
//! The renderer here is `core.StubRender`, which exposes NO
//! `loadTextureFromMemory`. That is deliberate: the image shims must be
//! renderer-capability-agnostic (the catalog uploads through the injected
//! `ImageBackend`, never through the renderer seam), exactly like the
//! sound and font shims. Compiling this file at all is that assertion.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const TestGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
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

// ── Mock ImageBackend ──
//
// The image loader's `backend` slot is a process-global, so every test
// installs this mock and clears it again on the way out.
const Mock = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var next_tex: engine.AssetTexture = 500;
    var decode_fails: bool = false;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        next_tex = 500;
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
        @memset(pixels, 0x2A);
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

const fake_png: []const u8 = "fake-png-bytes";

/// `file_type` for a loose PNG, WITH the leading dot.
///
/// Reviewed and confirmed against both sides of the seam (#832 review) —
/// a bot flagged this as inconsistent with `"png"`; it is not:
///
///   * labelle-assembler#676 (MERGED) is the producer, and its `.image`
///     arm emits `g.assets.register("<name>", .image, ".png", …)` — dot
///     included, explicitly "the same spelling the atlas arm passes".
///   * the atlas arm has always emitted `".png"` into
///     `registerAtlasFromMemory`.
///   * raylib is the consumer that actually READS this: `decodeImage`
///     forwards it to `LoadImageFromMemory`, which `strcmp`s against
///     `".png"` / `".PNG"` / … and returns an empty image for anything
///     else. `"png"` would be a hard decode failure on that backend.
///     (sokol ignores the argument entirely — stb sniffs magic bytes —
///     so it cannot catch the difference either way.)
///
/// The dotless spelling IS the contract for `.sound` / `.font`, whose
/// decoders dispatch on `"wav"` / `"ogg"` / `"ttf"`. Images and audio
/// genuinely differ here; do not "unify" them.
const png_type: [:0]const u8 = ".png";

const fake_wav: []const u8 = "fake-wav-bytes";
const wav_type: [:0]const u8 = "wav";

/// The handle an `Image` entity would draw with, or null when the asset
/// is not resident — i.e. the exact resolution the render seam performs.
fn drawableHandle(game: *TestGame, name: []const u8) ?engine.AssetTexture {
    if (!game.assets.isReady(name)) return null;
    const entry = game.assets.entries.getPtr(name) orelse return null;
    const resource = entry.resource orelse return null;
    return switch (resource) {
        .image => |t| t,
        else => null,
    };
}

// ── Hard-deadline harness ──
//
// Lives in `test/load_deadline.zig` since #833, where the atlas shim's
// deadlock test needed the same guarantee. See that file for why the
// deadline aborts the process rather than reporting a failure.

const deadline = @import("load_deadline.zig");

fn loadImageWithDeadline(game: *TestGame, name: []const u8) deadline.Outcome {
    return deadline.callWithDeadline(TestGame, "loadImageIfNeeded", game, name);
}

const expectDeadlineError = deadline.expectError;

// ── Tests ──

test "image shim: loadImageFromMemory is drawable on the FIRST frame" {
    // The property #831 exists for. No tick, no pump, no frame between
    // the load and the assertion — the asset must already be resident
    // with a real texture handle when the call returns.
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.loadImageFromMemory("portrait", png_type, fake_png);

    try testing.expect(game.assets.isReady("portrait"));
    try testing.expectEqual(@as(?engine.AssetTexture, 500), drawableHandle(&game, "portrait"));
    try testing.expectEqual(@as(u32, 1), Mock.decode_calls);
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "image shim: acquire alone is NOT ready on the first frame — the #831 gap" {
    // The pre-#831 eager emission (`assets.register` + `assets.acquire`,
    // labelle-assembler#676). This is the contrast that makes the test
    // above meaningful: the decode is merely STARTED, so a first-frame
    // draw resolves no handle and the `Image` entity is skipped.
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("acquired", .image, png_type, fake_png);
    _ = try game.assets.acquire("acquired");

    try testing.expectEqual(@as(?engine.AssetTexture, null), drawableHandle(&game, "acquired"));

    // …and it only becomes drawable once something pumps the catalog,
    // which in a real game is the next tick — one frame too late.
    while (!game.assets.isReady("acquired")) {
        game.assets.pump();
        std.Thread.yield() catch {};
    }
    try testing.expect(drawableHandle(&game, "acquired") != null);
}

test "image shim: registerImageFromMemory is lazy — no decode until asked" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("lazy_img", png_type, fake_png);
    try testing.expect(!game.assets.isReady("lazy_img"));
    try testing.expectEqual(@as(u32, 0), Mock.decode_calls);

    try testing.expect(try game.loadImageIfNeeded("lazy_img"));
    try testing.expect(drawableHandle(&game, "lazy_img") != null);
    try testing.expectEqual(@as(u32, 1), Mock.decode_calls);
}

test "image shim: loadImageIfNeeded twice is idempotent — second call is a no-op" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("twice", png_type, fake_png);
    try testing.expect(try game.loadImageIfNeeded("twice"));
    try testing.expectEqual(@as(bool, false), try game.loadImageIfNeeded("twice"));
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "image shim: double register is tolerated (manifest already registered it)" {
    // Same contract as every other `register*FromMemory` shim: the
    // assembler's scene manifest may have registered the name already.
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("shared", .image, png_type, fake_png);
    try game.loadImageFromMemory("shared", png_type, fake_png);
    try testing.expect(drawableHandle(&game, "shared") != null);
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);
}

test "image shim: loadImageIfNeeded on an unregistered name returns AssetNotRegistered" {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expectError(error.AssetNotRegistered, game.loadImageIfNeeded("ghost"));
}

test "image shim: a decode error surfaces within 200ms instead of hanging" {
    // The blocking loop's error exit. Without it a failed decode would
    // spin forever, because `isReady` never flips. The deadline is
    // ENFORCED (`loadImageWithDeadline` aborts rather than joining a
    // wedged worker), so a regression fails CI at 200ms instead of
    // stalling it.
    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("dead", png_type, fake_png);

    try expectDeadlineError(loadImageWithDeadline(&game, "dead"), error.MockDecodeFailure);
    try testing.expectEqual(@as(?engine.AssetTexture, null), drawableHandle(&game, "dead"));
}

test "image shim: a blocking load while the GPU surface is lost fails fast, not deadlocks" {
    // Regression for the P1 on #832. `surfaceLost` clears the catalog's
    // `gpu_alive` gate and then emits `engine__surface_lost`
    // SYNCHRONOUSLY (#820/#823) — so a hook that (re-)loads an image runs
    // with image uploads already PARKED on the result ring. The old code
    // entered the busy-wait there and could never leave it: `pump` refuses
    // to upload into a dead context, so the entry never reaches `.ready`
    // and never reaches `.failed`. That wedges `surfaceLost` itself, and
    // `surfaceRestored` — the only thing that reopens the gate — can then
    // never run.
    //
    // Deadline-guarded on purpose: without the fix this test does not
    // "fail slowly", it hangs, which is precisely what the harness turns
    // into a fast, named CI failure.
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("hud", png_type, fake_png);

    game.surfaceLost();
    try testing.expect(!game.assets.gpu_alive);

    try expectDeadlineError(loadImageWithDeadline(&game, "hud"), error.GpuSurfaceUnavailable);
    // Nothing was uploaded into the dead context, and the guard fires
    // BEFORE `acquire`, so no phantom refcount is left pinning the entry.
    try testing.expectEqual(@as(u32, 0), Mock.upload_calls);
    try testing.expectEqual(@as(u32, 0), game.assets.entries.get("hud").?.refcount);

    // INIT_WINDOW reopens the gate; the very same call now works.
    game.surfaceRestored();
    try testing.expect(game.assets.gpu_alive);
    try testing.expect(try game.loadImageIfNeeded("hud"));
    try testing.expect(drawableHandle(&game, "hud") != null);
}

test "image shim: a name already registered as a sound is rejected, not silently loaded" {
    // Regression for the kind-collision P2 on #832. `registerImageFromMemory`
    // swallows `AssetAlreadyRegistered`, and the blocking loader underneath
    // is kind-agnostic — so without a kind check a name the manifest already
    // registered as audio would decode its WAV, report success, and leave the
    // `Image` component with no `.image` handle to draw. A silent missing
    // image is the worst possible outcome for a name collision.
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Register-only: no audio backend is touched, and none is needed —
    // the point is that the image path must never get far enough to
    // decode it.
    try game.registerSoundFromMemory("collide", wav_type, fake_wav);

    try testing.expectError(error.WrongAssetKind, game.registerImageFromMemory("collide", png_type, fake_png));
    try testing.expectError(error.WrongAssetKind, game.loadImageFromMemory("collide", png_type, fake_png));
    try testing.expectError(error.WrongAssetKind, game.loadImageIfNeeded("collide"));

    // The audio entry is untouched — rejecting the collision must not
    // clobber the resource that legitimately owns the name.
    const entry = game.assets.entries.get("collide").?;
    try testing.expectEqual(engine.LoaderKind.audio, entry.loader_kind);
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(@as(u32, 0), Mock.decode_calls);
}

test "image shim: a failed load releases its refcount and stays retryable" {
    // Mirrors the atlas shim's `errdefer release` regression: a failed
    // load must not leave a phantom refcount pinning the entry, and the
    // entry must be rewound to `.registered` so a retry re-enqueues.
    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("retry", png_type, fake_png);
    try testing.expectError(error.MockDecodeFailure, game.loadImageIfNeeded("retry"));

    const entry = game.assets.entries.get("retry").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);

    // The retry actually re-decodes rather than replaying the stale error.
    Mock.decode_fails = false;
    try testing.expect(try game.loadImageIfNeeded("retry"));
    try testing.expect(drawableHandle(&game, "retry") != null);
    try testing.expectEqual(@as(u32, 2), Mock.decode_calls);
}

test "image shim: a failed load under a second holder stays retryable, not AssetDecodeNotQueued" {
    // Regression for the refcount-trap P2 on #832.
    //
    // When a scene (or any other async path) already holds the asset, our
    // `acquire` bumps the refcount 1 → 2, so the shim's `errdefer release`
    // only drops it back to 1. The old code also called `resetFailed`,
    // which rewound the SHARED entry to `.registered` while that nonzero
    // refcount remained — and `acquire` enqueues only on the 0 → 1
    // transition, so nothing could ever re-queue it. Every subsequent
    // attempt then returned `AssetDecodeNotQueued` instead of the real
    // error, for as long as the unrelated holder lived.
    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("pinned", png_type, fake_png);

    // The other holder — a scene manifest's eager `acquire`.
    _ = try game.assets.acquire("pinned");

    try expectDeadlineError(loadImageWithDeadline(&game, "pinned"), error.MockDecodeFailure);
    // Only OUR reference was returned; the other holder still owns theirs.
    try testing.expectEqual(@as(u32, 1), game.assets.entries.get("pinned").?.refcount);

    // The retry reports the REAL failure again. Before the fix this was
    // `error.AssetDecodeNotQueued` — a bogus error that hides the cause
    // and never recovers.
    try expectDeadlineError(loadImageWithDeadline(&game, "pinned"), error.MockDecodeFailure);

    // Once the other holder lets go, the entry rewinds to `.registered`
    // (that rewind belongs to the final `release`, not to us) and a retry
    // genuinely re-decodes.
    game.assets.release("pinned");
    Mock.decode_fails = false;
    try testing.expect(try game.loadImageIfNeeded("pinned"));
    try testing.expect(drawableHandle(&game, "pinned") != null);
    try testing.expect(Mock.decode_calls >= 2);
}
