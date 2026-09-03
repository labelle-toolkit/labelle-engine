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
// Two bots flagged the original shape of the timeout below: it `join()`ed
// the worker unconditionally, so a loader that regressed into an unbounded
// spin HUNG CI instead of failing at the deadline. A test that cannot fail
// is worse than no test, so the deadline is now real.
//
// There is no SAFE in-process recovery from a wedged loader. The worker
// thread owns `*TestGame`: joining it waits forever by construction, and
// returning without joining lets the caller's `defer game.deinit()` free the
// catalog out from under a thread that is still pumping it (and leaves
// `testing.allocator`'s leak check racing a live thread). Full process
// isolation — fork a child, watchdog it, reap it — is the textbook answer
// and is out of proportion to one regression guard in a unit-test binary.
//
// So the deadline is enforced by killing the process: print exactly what
// wedged, then `abort()`. CI fails LOUDLY at 200 ms with a named regression
// instead of stalling until the job timeout. Nothing but a genuine
// regression can reach that branch.

const DeadlineOutcome = union(enum) {
    ok: bool,
    err: anyerror,
};

const deadline_ns: u64 = 200 * std.time.ns_per_ms;

/// `game.loadImageIfNeeded(name)` on a worker thread under a hard deadline.
/// Returns its outcome, or aborts the process if it does not return in time.
fn loadImageWithDeadline(game: *TestGame, name: []const u8) DeadlineOutcome {
    const Runner = struct {
        outcome: DeadlineOutcome = .{ .err = error.RunnerNeverRan },
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This(), g: *TestGame, n: []const u8) void {
            if (g.loadImageIfNeeded(n)) |did_load| {
                self.outcome = .{ .ok = did_load };
            } else |err| {
                self.outcome = .{ .err = err };
            }
            self.done.store(true, .release);
        }
    };

    var runner = Runner{};
    const handle = std.Thread.spawn(.{}, Runner.run, .{ &runner, game, name }) catch |err| {
        std.debug.print("image_load_shim_test: thread spawn failed: {s}\n", .{@errorName(err)});
        std.process.abort();
    };

    // Zig 0.16 has neither `std.Thread.sleep` nor `std.time.Timer`, so the
    // deadline is counted in libc `nanosleep` steps — the same primitive
    // every other timing-sensitive test in this repo falls back to.
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        if (runner.done.load(.acquire)) break;
        var req: std.c.timespec = .{
            .sec = @intCast(step_ns / std.time.ns_per_s),
            .nsec = @intCast(step_ns % std.time.ns_per_s),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }

    if (!runner.done.load(.acquire)) {
        std.debug.print(
            "\n" ++
                "image_load_shim_test: REGRESSION — loadImageIfNeeded(\"{s}\") did not return\n" ++
                "within {d}ms. The blocking loop is wedged (see src/game/atlas_mixin.zig\n" ++
                "loadAssetIfNeededInternal). Aborting so this FAILS CI now rather than\n" ++
                "hanging it; the worker owns the Game, so there is no safe way to unwind.\n",
            .{ name, deadline_ns / std.time.ns_per_ms },
        );
        std.process.abort();
    }

    // `join` establishes happens-before with the worker's writes, so the
    // plain read of `runner.outcome` below is well-defined.
    handle.join();
    return runner.outcome;
}

fn expectDeadlineError(outcome: DeadlineOutcome, expected: anyerror) !void {
    switch (outcome) {
        .ok => |did_load| {
            std.debug.print(
                "expected {s}, but the load SUCCEEDED (did_load = {})\n",
                .{ @errorName(expected), did_load },
            );
            return error.TestUnexpectedResult;
        },
        .err => |err| try testing.expectEqual(expected, err),
    }
}

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
