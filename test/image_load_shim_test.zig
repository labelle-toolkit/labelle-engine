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
const png_type: [:0]const u8 = ".png";

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
    // The blocking loop's other exit. Without it a failed decode would
    // spin forever, because `isReady` never flips. Mirrors the atlas
    // shim's deadlock regression test: the load runs on a background
    // thread so the main thread can impose a deadline, and a runaway
    // spin fails CI instead of stalling it.
    Mock.reset();
    Mock.decode_fails = true;
    engine.ImageLoader.setBackend(Mock.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("dead", png_type, fake_png);

    const Runner = struct {
        result: ?anyerror = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This(), g: *TestGame) void {
            if (g.loadImageIfNeeded("dead")) |_| {
                self.result = null;
            } else |err| {
                self.result = err;
            }
            self.done.store(true, .release);
        }
    };
    var runner = Runner{};
    const handle = try std.Thread.spawn(.{}, Runner.run, .{ &runner, &game });

    // Zig 0.16 has neither `std.Thread.sleep` nor `std.time.Timer`, so the
    // deadline is counted in libc `nanosleep` steps — the same primitive
    // every other timing-sensitive test in this repo falls back to.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
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
    const terminated = runner.done.load(.acquire);
    handle.join();
    try testing.expect(terminated);
    try testing.expectEqual(@as(?anyerror, error.MockDecodeFailure), runner.result);
    try testing.expectEqual(@as(?engine.AssetTexture, null), drawableHandle(&game, "dead"));
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
