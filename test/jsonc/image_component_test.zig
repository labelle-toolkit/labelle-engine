//! Standalone `Image` component (labelle-engine#568) — scene-loader + loader
//! resolution coverage.
//!
//! Two things are proven here:
//!   1. A scene entity with an `"Image"` block parses into the engine
//!      built-in `Image` component with the RFC field shape
//!      (`name` / `pivot` / `layer` / `z_index` / `visible`).
//!   2. The `Image.name` the loader parsed resolves end-to-end through the
//!      `AssetCatalog` `image` loader — register → acquire → worker-decode →
//!      upload → `.ready` → GPU texture handle — the same path
//!      `bridgeImageAssetsToAtlasManager` bridges into the renderer.
//!
//! A third test guards the built-in precedence rule: a project-registered
//! component named `Image` wins over the engine built-in (mirrors the
//! `Tilemap` / `Camera` precedence contract in `component_apply.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const image_loader = engine.ImageLoader;

const MockEcs = core.MockEcsBackend(u32);

fn Game(comptime Components: type) type {
    return engine.game_mod.GameConfig(
        core.StubRender(MockEcs.Entity),
        MockEcs,
        engine.input_mod.StubInput,
        engine.audio_mod.StubAudio,
        engine.StubVideo,
        engine.gui_mod.StubGui,
        void,
        core.StubLogSink,
        Components,
        &.{},
        void,
    );
}

// No project component named `Image` — the engine built-in is active.
const BuiltinComponents = engine.ComponentRegistry(.{});
const BuiltinGame = Game(BuiltinComponents);
const BuiltinBridge = engine.JsoncSceneBridge(BuiltinGame, BuiltinComponents);

// ---------------------------------------------------------------------
// Mock image backend — 1×1 RGBA, mirrors asset_catalog_test's shape.
// ---------------------------------------------------------------------

const Mock = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var next_tex: engine.AssetTexture = 100;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        next_tex = 100;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!engine.DecodedImage {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0x7F);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(decoded: engine.DecodedImage) anyerror!engine.AssetTexture {
        _ = decoded;
        upload_calls += 1;
        const t = next_tex;
        next_tex += 1;
        return t;
    }

    fn unloadFn(texture: engine.AssetTexture) void {
        _ = texture;
    }

    const backend: engine.ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "Image: scene entity parses into the engine built-in with the RFC shape" {
    var game = BuiltinGame.init(testing.allocator);
    defer game.deinit();

    try BuiltinBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Image": {
        \\      "name": "logo_splash",
        \\      "pivot": "bottom_left",
        \\      "layer": "ui",
        \\      "z_index": 10,
        \\      "visible": true
        \\  } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{engine.Image}, .{});
    defer view.deinit();
    const ent = view.next().?;

    const img = game.ecs_backend.getComponent(ent, engine.Image).?;
    try testing.expectEqualStrings("logo_splash", img.name);
    try testing.expectEqual(engine.ImagePivot.bottom_left, img.pivot);
    try testing.expectEqualStrings("ui", img.layer);
    try testing.expectEqual(@as(i16, 10), img.z_index);
    try testing.expect(img.visible);
}

test "Image: defaults land for a minimal block" {
    var game = BuiltinGame.init(testing.allocator);
    defer game.deinit();

    try BuiltinBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Image": { "name": "bare" } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{engine.Image}, .{});
    defer view.deinit();
    const img = game.ecs_backend.getComponent(view.next().?, engine.Image).?;
    try testing.expectEqualStrings("bare", img.name);
    try testing.expectEqual(engine.ImagePivot.center, img.pivot);
    try testing.expectEqualStrings("", img.layer);
    try testing.expectEqual(@as(i16, 0), img.z_index);
    try testing.expect(img.visible);
}

test "Image: parsed name resolves end-to-end through the AssetCatalog image loader" {
    Mock.reset();
    image_loader.setBackend(Mock.backend);
    defer image_loader.clearBackend();

    var game = BuiltinGame.init(testing.allocator);
    defer game.deinit();

    // The standalone PNG the scene's `Image` will reference. In a real game
    // this registration comes from `project.labelle` `.resources` (a
    // `.texture`-only, `.json`-less entry → the `image` loader). Here we
    // register it directly on the game's catalog.
    try game.assets.register("logo_splash", engine.LoaderKind.image, "png", "fake-png-bytes");

    try BuiltinBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Image": { "name": "logo_splash", "pivot": "center" } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    // Pull the asset key straight off the loaded component so this test
    // exercises exactly what the scene loader parsed.
    var view = game.ecs_backend.view(.{engine.Image}, .{});
    defer view.deinit();
    const img = game.ecs_backend.getComponent(view.next().?, engine.Image).?;
    try testing.expectEqualStrings("logo_splash", img.name);

    // Resolve `img.name` through the image loader.
    try testing.expect(!game.assets.isReady(img.name));
    _ = try game.assets.acquire(img.name);

    // Drain the worker's decoded payload (pump() is a no-op until #442, so
    // finalize by hand — same shape as asset_catalog_test).
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    const result = outer: while (waited_ns < deadline_ns) {
        for (&game.assets.results) |*ring| {
            if (ring.tryDequeue()) |r| break :outer r;
        }
        {
            var req: std.c.timespec = .{ .sec = (step_ns / std.time.ns_per_s), .nsec = (step_ns % std.time.ns_per_s) };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        }
        waited_ns += step_ns;
    } else {
        return error.WorkerDidNotRespond;
    };

    try testing.expectEqualStrings("logo_splash", result.entry_name);
    try testing.expect(result.err == null);
    try testing.expect(result.decoded != null);
    try testing.expectEqual(@as(u32, 1), Mock.decode_calls);

    const entry = game.assets.entries.getPtr(img.name).?;
    try result.vtable.upload(entry, result.decoded.?, testing.allocator);
    entry.decoded = null;
    entry.state = .ready;

    // The Image's asset is now resolved: ready, with an uploaded GPU texture
    // handle — exactly what `bridgeImageAssetsToAtlasManager` reads to wire
    // the renderer.
    try testing.expect(game.assets.isReady(img.name));
    try testing.expect(entry.resource != null);
    const tex = switch (entry.resource.?) {
        .image => |t| t,
        else => return error.WrongResourceKind,
    };
    try testing.expect(tex >= 100);
    try testing.expectEqual(@as(u32, 1), Mock.upload_calls);

    game.assets.release(img.name);
}

// ---------------------------------------------------------------------
// Precedence — a project-registered `Image` wins over the built-in.
// ---------------------------------------------------------------------

/// A project component that happens to be named `Image`, with a shape
/// distinct from the engine built-in.
const ProjectImage = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    width: i32 = 0,
    height: i32 = 0,
};

const OverrideComponents = engine.ComponentRegistry(.{
    .Image = ProjectImage,
});
const OverrideGame = Game(OverrideComponents);
const OverrideBridge = engine.JsoncSceneBridge(OverrideGame, OverrideComponents);

test "Image: a registered component named Image wins over the engine built-in" {
    var game = OverrideGame.init(testing.allocator);
    defer game.deinit();

    try OverrideBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Image": { "width": 320, "height": 240 } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{ProjectImage}, .{});
    defer view.deinit();
    const ent = view.next().?;
    const pimg = game.ecs_backend.getComponent(ent, ProjectImage).?;
    try testing.expectEqual(@as(i32, 320), pimg.width);
    try testing.expectEqual(@as(i32, 240), pimg.height);

    // The engine built-in `Image` must NOT have been attached to the entity.
    try testing.expect(game.getComponent(ent, engine.Image) == null);
}
