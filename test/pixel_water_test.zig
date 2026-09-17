//! `PixelWater` — the engine's authoring + runtime half of the built-in
//! pixel-water material (COND-07, labelle-bgfx#100, RFC-PIXEL-WATER phase 5).
//!
//! WHAT THESE TESTS ARE FOR, AND WHAT THEY DELIBERATELY ARE NOT.
//!
//! Ripple expiry, the eight-slot cap and the deterministic oldest-replacement
//! at capacity live in labelle-gfx's water-instance store and are tested
//! there. Re-testing them against the mock below would only prove the mock.
//! What is tested here is everything the ENGINE owns and gfx cannot:
//!
//!   * authoring parity — JSONC and comptime `.zon` land identical settings,
//!   * validation, with the entity and the offending field named,
//!   * the bounded-strength rule at BOTH boundaries (authored pixel amplitude
//!     and runtime dimensionless scale),
//!   * stage-before-commit — a rejected update leaves the component AND the
//!     gfx instance on the previous settings,
//!   * simulation time arriving from the engine's time-scaled step, so pause
//!     and slow-mo apply and nothing reads a wall clock,
//!   * instance lifetime across destroy / scene reset / re-author,
//!   * the public API being reachable through `engine.*`.
//!
//! ASSERTING THE MECHANISM. Several of these could be made to pass by a
//! fallback that happens to produce the same value — a "component unchanged"
//! assertion, for instance, is satisfied both by a correct rejection and by an
//! update that never ran at all. So the mock renderer COUNTS every call it
//! receives, and the tests assert which path ran (`set_settings_calls`,
//! `ripple_calls`, `advance_calls`, `release_calls`) alongside the value.
//!
//! The renderer is a local mock rather than the real labelle-gfx one on
//! purpose: the engine takes no gfx dependency, and the whole water seam is
//! reached by `@hasDecl`. Compiling `NoWaterGame` at the bottom of this file
//! IS the assertion that a renderer without the seam still builds.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const Material = core.backend_contract.Material;
const MockEcs = core.MockEcsBackend(u32);
const PixelWater = engine.PixelWater;
const PixelWaterSettings = engine.PixelWaterSettings;

/// Whether the pinned labelle-core carries `MaterialEffect.pixel_water`
/// (labelle-core#78). The engine's binding is `@hasField`-gated so it compiles
/// against either pin; this mirror lets the test assert the RIGHT thing on
/// each — the effect tag when it exists, the untouched `.none` fallback when
/// it does not — instead of being silently skipped.
const has_pixel_water_effect = @hasField(core.backend_contract.MaterialEffect, "pixel_water");

// ── Mock renderer with the labelle-gfx#359 water seam ───────────────────

/// Mirrors the shape of gfx's `WaterInstanceId`: generational, with
/// `generation == 0` reserved for "none", so the all-zero default IS `.none`.
const MockWaterId = struct {
    index: u32 = 0,
    generation: u32 = 0,
    pub const none: MockWaterId = .{};
    pub fn isNone(self: MockWaterId) bool {
        return self.generation == 0;
    }
};

const MockRgba = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 0 };

/// Field-for-field the subset of gfx's `WaterConfig` the engine writes.
const MockWaterConfig = struct {
    mask: u32 = 0,
    reflection: u32 = 0,
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    grid_pixels: u32 = 1,
    deep: MockRgba = .{},
    surface: MockRgba = .{},
    highlight: MockRgba = .{},
    wave_amplitude_pixels: f32 = 0,
    wave_period_seconds: f32 = 1,
    waves_enabled: bool = true,
    distortion_pixels: f32 = 0,
    reflection_opacity: f32 = 0,
    ripple_duration_seconds: f32 = 0.8,
    ripple_radius_pixels: f32 = 6,
    ripple_strength_pixels: f32 = 1,
};

const MockWaterState = struct {
    config: MockWaterConfig = .{},
    level: f32 = 0,
    time: f32 = 0,
    ripple_count: u32 = 0,
    live: bool = false,
    generation: u32 = 1,
};

fn WaterRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            material: Material = .{},
            water: MockWaterId = .none,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        // ── The water seam the engine detects via @hasDecl ──
        pub const WaterInstanceId = MockWaterId;
        pub const WaterConfig = MockWaterConfig;
        pub const WaterState = MockWaterState;

        visual_dirty_count: usize = 0,

        slots: [8]MockWaterState = [_]MockWaterState{.{}} ** 8,
        live_count: usize = 0,

        // Call counters — the "which path ran" half of every assertion.
        create_calls: usize = 0,
        release_calls: usize = 0,
        set_settings_calls: usize = 0,
        set_level_calls: usize = 0,
        ripple_calls: usize = 0,
        advance_calls: usize = 0,
        /// Sum of every dt handed to `advanceWaterTime`. Proves the engine's
        /// time-scaled delta is what reaches the simulation.
        advanced_dt_total: f32 = 0,

        /// Simulates gfx's own validation rejecting a candidate — the second
        /// of the two stage-before-commit rejection paths.
        reject_settings: bool = false,
        /// Simulates the instance store being out of room.
        fail_create: bool = false,
        /// Simulates gfx refusing a level write — the failure mode that
        /// used to leave a live instance at the default level while the
        /// component read the authored one.
        fail_level: bool = false,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }

        fn slot(self: *Self, id: MockWaterId) ?*MockWaterState {
            if (id.generation == 0 or id.index >= self.slots.len) return null;
            const s = &self.slots[id.index];
            if (!s.live or s.generation != id.generation) return null;
            return s;
        }

        pub fn createWaterInstance(self: *Self, config: MockWaterConfig) !MockWaterId {
            self.create_calls += 1;
            if (self.fail_create) return error.OutOfMemory;
            for (&self.slots, 0..) |*s, i| {
                if (s.live) continue;
                s.* = .{ .config = config, .live = true, .generation = s.generation };
                self.live_count += 1;
                return .{ .index = @intCast(i), .generation = s.generation };
            }
            return error.OutOfMemory;
        }

        pub fn releaseWaterInstance(self: *Self, id: MockWaterId) bool {
            const s = self.slot(id) orelse return false;
            const gen = s.generation +% 1;
            s.* = .{ .generation = if (gen == 0) 1 else gen };
            self.live_count -= 1;
            self.release_calls += 1;
            return true;
        }

        pub fn waterInstanceCount(self: *const Self) usize {
            return self.live_count;
        }

        pub fn waterState(self: *const Self, id: MockWaterId) ?*const MockWaterState {
            if (id.generation == 0 or id.index >= self.slots.len) return null;
            const s = &self.slots[id.index];
            if (!s.live or s.generation != id.generation) return null;
            return s;
        }

        pub fn setWaterSettings(self: *Self, id: MockWaterId, config: MockWaterConfig) !void {
            self.set_settings_calls += 1;
            const s = self.slot(id) orelse return error.StaleInstance;
            // Like gfx: a rejection leaves the PREVIOUS settings intact.
            if (self.reject_settings) return error.NonFiniteValue;
            s.config = config;
        }

        pub fn reconfigureWater(self: *Self, id: MockWaterId, config: MockWaterConfig) !void {
            const s = self.slot(id) orelse return error.StaleInstance;
            s.config = config;
        }

        pub fn setWaterLevel(self: *Self, id: MockWaterId, level: f32) !void {
            self.set_level_calls += 1;
            const s = self.slot(id) orelse return error.StaleInstance;
            if (self.fail_level) return error.OutOfMemory;
            if (!std.math.isFinite(level)) return error.NonFiniteValue;
            s.level = std.math.clamp(level, 0, 1);
            if (s.level == 0) s.ripple_count = 0;
        }

        pub fn setWaterTime(self: *Self, id: MockWaterId, t: f32) !void {
            const s = self.slot(id) orelse return error.StaleInstance;
            s.time = t;
        }

        pub fn advanceWaterTime(self: *Self, id: MockWaterId, dt: f32) !void {
            self.advance_calls += 1;
            self.advanced_dt_total += dt;
            const s = self.slot(id) orelse return error.StaleInstance;
            s.time += dt;
        }

        pub fn setWaterWavesEnabled(self: *Self, id: MockWaterId, on: bool) !void {
            const s = self.slot(id) orelse return error.StaleInstance;
            s.config.waves_enabled = on;
        }

        pub fn addWaterRipple(self: *Self, id: MockWaterId, x: f32, strength: f32) !void {
            self.ripple_calls += 1;
            const s = self.slot(id) orelse return error.StaleInstance;
            if (!std.math.isFinite(x) or !std.math.isFinite(strength)) return error.NonFiniteValue;
            if (s.level <= 0) return error.EmptyReservoir;
            const w: f32 = @floatFromInt(s.config.logical_width);
            if (x < 0 or x >= w) return error.RippleOutOfBounds;
            if (s.ripple_count < 8) s.ripple_count += 1;
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
    WaterRenderer(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

// ── Mock image backend, so a mask/reflection can become resident ────────

const Mock = struct {
    var next_tex: engine.AssetTexture = 700;

    fn reset() void {
        next_tex = 700;
    }
    fn decodeFn(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) anyerror!engine.DecodedImage {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0x11);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }
    fn uploadFn(_: engine.DecodedImage) anyerror!engine.AssetTexture {
        const t = next_tex;
        next_tex += 1;
        return t;
    }
    fn unloadFn(_: engine.AssetTexture) void {}

    const backend: engine.ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

const png_type: [:0]const u8 = ".png";
const fake_png: []const u8 = "fake-png-bytes";

fn installImageBackend() void {
    Mock.reset();
    engine.ImageLoader.setBackend(Mock.backend);
}

fn loadMask(game: *TestGame, name: []const u8) !void {
    try game.loadImageFromMemory(name, png_type, fake_png);
}

/// The catalog refcount held on `name`. The reservoir's asset references are
/// invisible in behaviour until something evicts a texture, so every
/// acquire/release assertion below reads this directly.
fn refcount(game: *TestGame, name: []const u8) u32 {
    return game.assets.entries.getPtr(name).?.refcount;
}

/// The canonical authored reservoir — the RFC's example block, with the
/// illustrative asset names swapped for the two this file loads.
fn authored() PixelWater {
    return .{
        .mask = "reservoir_mask",
        .reflection = "reflection",
        .logical_size = .{ 96, 18 },
        .grid_pixels = 1,
        .water_level = 0.35,
        .deep_color = "#172D36",
        .surface_color = "#507B8B",
        .highlight_color = "#ADCAC6",
        .wave_amplitude_pixels = 1,
        .wave_period_seconds = 3,
        .reflection_opacity = 0.25,
        .distortion_pixels = 1,
        .ripple_duration_seconds = 0.8,
        .ripple_radius_pixels = 6,
        .ripple_strength_pixels = 1,
    };
}

/// Spawn a fully-resolved reservoir: assets resident, sprite attached,
/// component authored, gfx instance live.
fn spawnReservoir(game: *TestGame) !MockEcs.Entity {
    try loadMask(game, "reservoir_mask");
    try loadMask(game, "reflection");
    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "reservoir" });
    try testing.expect(game.addPixelWater(e, authored()));
    try testing.expect(game.waterInstance(e) != null);
    return e;
}

// ── Authoring: JSONC / .zon parity ──────────────────────────────────────

const authored_jsonc =
    \\{
    \\  "mask": "reservoir_mask",
    \\  "reflection": "reflection",
    \\  "logical_size": [96, 18],
    \\  "grid_pixels": 1,
    \\  "water_level": 0.35,
    \\  "deep_color": "#172D36",
    \\  "surface_color": "#507B8B",
    \\  "highlight_color": "#ADCAC6",
    \\  "wave_amplitude_pixels": 1,
    \\  "wave_period_seconds": 3,
    \\  "reflection_opacity": 0.25,
    \\  "distortion_pixels": 1,
    \\  "ripple_duration_seconds": 0.8,
    \\  "ripple_radius_pixels": 6,
    \\  "ripple_strength_pixels": 1
    \\}
;

/// The identical reservoir as a comptime `.zon` component value — the shape
/// `scene/src/entity_writer.zig` coerces.
const authored_zon = .{
    .mask = "reservoir_mask",
    .reflection = "reflection",
    .logical_size = .{ 96, 18 },
    .grid_pixels = 1,
    .water_level = 0.35,
    .deep_color = "#172D36",
    .surface_color = "#507B8B",
    .highlight_color = "#ADCAC6",
    .wave_amplitude_pixels = 1,
    .wave_period_seconds = 3,
    .reflection_opacity = 0.25,
    .distortion_pixels = 1,
    .ripple_duration_seconds = 0.8,
    .ripple_radius_pixels = 6,
    .ripple_strength_pixels = 1,
};

fn expectSameComponent(a: PixelWater, b: PixelWater) !void {
    try testing.expectEqualStrings(a.mask, b.mask);
    try testing.expectEqualStrings(a.reflection, b.reflection);
    try testing.expectEqual(a.logical_size, b.logical_size);
    try testing.expectEqual(a.grid_pixels, b.grid_pixels);
    try testing.expectEqual(a.water_level, b.water_level);
    try testing.expectEqualStrings(a.deep_color, b.deep_color);
    try testing.expectEqualStrings(a.surface_color, b.surface_color);
    try testing.expectEqualStrings(a.highlight_color, b.highlight_color);
    try testing.expectEqual(a.wave_amplitude_pixels, b.wave_amplitude_pixels);
    try testing.expectEqual(a.wave_period_seconds, b.wave_period_seconds);
    try testing.expectEqual(a.waves_enabled, b.waves_enabled);
    try testing.expectEqual(a.reflection_opacity, b.reflection_opacity);
    try testing.expectEqual(a.distortion_pixels, b.distortion_pixels);
    try testing.expectEqual(a.ripple_duration_seconds, b.ripple_duration_seconds);
    try testing.expectEqual(a.ripple_radius_pixels, b.ripple_radius_pixels);
    try testing.expectEqual(a.ripple_strength_pixels, b.ripple_strength_pixels);
}

test "authoring: JSONC and .zon produce the same PixelWater settings" {
    // Both formats must reach the SAME validated component through the SAME
    // helper — that is the point of routing the built-in through
    // `addPixelWater` rather than giving each format its own apply.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var parser = engine.JsoncParser.init(arena.allocator(), authored_jsonc);
    const value = try parser.parse();
    const from_json = engine.jsonc_deserializer.deserialize(
        PixelWater,
        value,
        arena.allocator(),
    ) orelse return error.JsoncDeserializeFailed;

    const from_zon = engine.scene_mod.EntityWriter(TestGame, EmptyComponents)
        .coerce(PixelWater, authored_zon);

    try expectSameComponent(from_json, from_zon);
    // …and both match the hand-written literal the rest of this file uses,
    // so a drift in any one of the three fails here rather than silently.
    try expectSameComponent(from_json, authored());
}

test "authoring: the JSONC array maps onto logical_size, not a zeroed default" {
    // `[2]u32` needs the deserializer's array branch. Without it the field
    // would fall back to its `.{0,0}` default — which validation rejects, so
    // the mechanism assertion is that the value ARRIVED, not merely that
    // something was produced.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = engine.JsoncParser.init(arena.allocator(), authored_jsonc);
    const value = try parser.parse();
    const comp = engine.jsonc_deserializer.deserialize(PixelWater, value, arena.allocator()).?;
    try testing.expectEqual(@as(u32, 96), comp.logical_size[0]);
    try testing.expectEqual(@as(u32, 18), comp.logical_size[1]);
}

// ── Asset resolution + instance lifetime ────────────────────────────────

test "instance: created once the mask is resident, and bound to the sprite" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);

    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());
    const id = game.waterInstance(e).?;

    // The draw binding: the sprite carries the id AND selects the effect.
    const sprite = game.getComponent(e, TestGame.SpriteComp).?;
    try testing.expect(!sprite.water.isNone());
    try testing.expectEqual(id.index, sprite.water.index);
    if (comptime has_pixel_water_effect) {
        try testing.expectEqual(
            @field(core.backend_contract.MaterialEffect, "pixel_water"),
            sprite.material.effect,
        );
    } else {
        // The pinned labelle-core predates core#78, so the effect tag does
        // not exist yet. The engine must then leave the sprite on `.none` —
        // the authored static-reservoir fallback — rather than inventing an
        // effect. This branch disappears the moment the pin carries the tag.
        try testing.expectEqual(core.backend_contract.MaterialEffect.none, sprite.material.effect);
    }

    // Structural + colour data actually reached gfx.
    const st = game.renderer.waterState(id).?;
    try testing.expectEqual(@as(u32, 96), st.config.logical_width);
    try testing.expectEqual(@as(u32, 18), st.config.logical_height);
    try testing.expectEqual(@as(u32, 700), st.config.mask);
    try testing.expectEqual(@as(u32, 701), st.config.reflection);
    try testing.expectApproxEqAbs(@as(f32, 0.35), st.level, 1e-6);
}

test "instance: a missing mask defers creation, then resolves when it lands" {
    // The streaming case. The important half is the MECHANISM: before the
    // asset is resident `createWaterInstance` must not have been called at
    // all — an assertion on "no instance" alone would also pass if creation
    // had been attempted and failed.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "reservoir" });
    try testing.expect(game.addPixelWater(e, authored()));

    try testing.expectEqual(@as(usize, 0), game.renderer.create_calls);
    try testing.expect(game.waterInstance(e) == null);

    try loadMask(&game, "reservoir_mask");
    engine.pixel_water_tick.tick(&game, 0);

    try testing.expectEqual(@as(usize, 1), game.renderer.create_calls);
    try testing.expect(game.waterInstance(e) != null);
    // The reflection never arrived; it is optional and degrades to "none".
    const st = game.renderer.waterState(game.waterInstance(e).?).?;
    try testing.expectEqual(@as(u32, 0), st.config.reflection);
}

test "lifetime: destroying the entity releases the instance" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());

    game.destroyEntity(e);
    engine.pixel_water_tick.tick(&game, 0);

    try testing.expectEqual(@as(usize, 1), game.renderer.release_calls);
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
    try testing.expect(game.waterInstance(e) == null);
}

test "lifetime: an ECS reset releases every instance" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    _ = try spawnReservoir(&game);
    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());

    game.clearPixelWaterInstances();

    try testing.expectEqual(@as(usize, 1), game.renderer.release_calls);
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
}

test "reload: re-authoring the same reservoir reuses the instance" {
    // "Changing settings must not create a new GPU program or silently
    // recreate the water instance." A non-structural re-author therefore must
    // NOT bump `create_calls`.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    const before = game.renderer.create_calls;
    const id_before = game.waterInstance(e).?;

    var next = authored();
    next.reflection_opacity = 0.5;
    try testing.expect(game.addPixelWater(e, next));

    try testing.expectEqual(before, game.renderer.create_calls);
    try testing.expectEqual(@as(usize, 0), game.renderer.release_calls);
    const id_after = game.waterInstance(e).?;
    try testing.expectEqual(id_before.index, id_after.index);
    try testing.expectEqual(id_before.generation, id_after.generation);
    try testing.expectApproxEqAbs(
        @as(f32, 0.5),
        game.renderer.waterState(id_after).?.config.reflection_opacity,
        1e-6,
    );
}

test "reload: a STRUCTURAL re-author recreates the instance" {
    // The contrasting half of the test above — without it, "reuses the
    // instance" could be satisfied by a path that never recreates anything.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    const before = game.renderer.create_calls;

    var next = authored();
    next.logical_size = .{ 64, 12 };
    try testing.expect(game.addPixelWater(e, next));
    engine.pixel_water_tick.tick(&game, 0);

    try testing.expectEqual(@as(usize, 1), game.renderer.release_calls);
    try testing.expectEqual(before + 1, game.renderer.create_calls);
    try testing.expectEqual(
        @as(u32, 64),
        game.renderer.waterState(game.waterInstance(e).?).?.config.logical_width,
    );
}

test "lifetime: the destroy releases the instance SYNCHRONOUSLY, before any tick" {
    // The reaper is the fallback for a bare `removeComponent`, not the
    // primary path: an ECS backend that recycles entity ids can hand a
    // reservoir created later in the SAME frame the dead entity's key, and
    // `resolvePixelWaterInstance` would then accept the stale instance
    // instead of building the new one. So the destroy itself must release.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    game.destroyEntity(e);

    // No tick in between — that is the whole assertion.
    try testing.expectEqual(@as(usize, 1), game.renderer.release_calls);
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
    try testing.expect(game.waterInstance(e) == null);
}

test "instance: a failed initial level sync releases the instance instead of reporting success" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try loadMask(&game, "reservoir_mask");
    try loadMask(&game, "reflection");
    game.renderer.fail_level = true;

    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "reservoir" });
    try testing.expect(game.addPixelWater(e, authored()));

    // MECHANISM: the instance WAS created and then handed back — not merely
    // never created. A swallowed level error would leave it live at the
    // default level while the component reads the authored 0.35.
    try testing.expectEqual(@as(usize, 1), game.renderer.create_calls);
    try testing.expectEqual(@as(usize, 1), game.renderer.release_calls);
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
    try testing.expect(game.waterInstance(e) == null);
    // And nothing half-bound is left on the sprite.
    try testing.expect(game.getComponent(e, TestGame.SpriteComp).?.water.isNone());
}

test "binding: a sprite added AFTER the water still gets bound" {
    // Authored component order is not guaranteed: `PixelWater` before
    // `Sprite`, with the mask already resident, creates the instance while
    // there is no sprite to bind. The per-frame resolve must finish the job
    // when the sprite shows up, or the effect never draws.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try loadMask(&game, "reservoir_mask");
    try loadMask(&game, "reflection");

    const e = game.createEntity();
    try testing.expect(game.addPixelWater(e, authored()));
    const id = game.waterInstance(e).?;

    game.addSprite(e, .{ .sprite_name = "reservoir" });
    try testing.expect(game.getComponent(e, TestGame.SpriteComp).?.water.isNone());

    game.tick(0);
    const sprite = game.getComponent(e, TestGame.SpriteComp).?;
    try testing.expect(!sprite.water.isNone());
    try testing.expectEqual(id.index, sprite.water.index);

    // MECHANISM: the rebind is equality-guarded, so a steady-state frame
    // does NOT re-dirty the visual. Without the guard this would climb by
    // one every tick and break the backend's draw batching.
    const dirty_after_bind = game.renderer.visual_dirty_count;
    game.tick(0);
    game.tick(0);
    try testing.expectEqual(dirty_after_bind, game.renderer.visual_dirty_count);
}

test "reflection: one that finishes streaming after the mask is still applied" {
    // Mask and reflection are acquired together but land independently. If
    // only the creation moment could apply the reflection, the completion
    // ORDER of two uploads would decide whether the authored reflection ever
    // appears — a nondeterministic visual.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try loadMask(&game, "reservoir_mask");
    // Registered but NOT resident: the streaming reflection.
    try game.registerImageFromMemory("reflection", png_type, fake_png);

    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "reservoir" });
    try testing.expect(game.addPixelWater(e, authored()));

    const id = game.waterInstance(e).?;
    try testing.expectEqual(@as(u32, 0), game.renderer.waterState(id).?.config.reflection);

    const settings_before = game.renderer.set_settings_calls;
    _ = try game.loadImageIfNeeded("reflection");
    game.tick(0);

    try testing.expect(game.renderer.waterState(id).?.config.reflection != 0);
    // MECHANISM: exactly ONE reconfigure ran…
    try testing.expectEqual(settings_before + 1, game.renderer.set_settings_calls);
    // …and the pending flag was cleared, so later frames do not re-push it.
    game.tick(0);
    game.tick(0);
    try testing.expectEqual(settings_before + 1, game.renderer.set_settings_calls);
}

// ── Asset references ────────────────────────────────────────────────────

test "assets: a reservoir pins its mask and reflection, and the destroy releases both" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    // The eager load holds one reference; the reservoir adds the second.
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reflection"));

    game.destroyEntity(e);
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reflection"));
}

test "assets: re-authoring the same names does not ratchet the refcount" {
    // Hot reload and live prefab refresh re-run `addPixelWater` on a live
    // component. An unconditional acquire would add one reference per pass
    // and pin the texture for the rest of the process.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try spawnReservoir(&game);
    const before = refcount(&game, "reservoir_mask");

    var again = authored();
    again.distortion_pixels = 0.5; // a non-structural re-author
    try testing.expect(game.addPixelWater(e, again));
    try testing.expect(game.addPixelWater(e, again));
    try testing.expectEqual(before, refcount(&game, "reservoir_mask"));

    // A STRUCTURAL re-author onto a different mask moves the reference:
    // the old name drops back, the new one is pinned.
    try loadMask(&game, "other_mask");
    var swapped = authored();
    swapped.mask = "other_mask";
    try testing.expect(game.addPixelWater(e, swapped));
    try testing.expectEqual(before - 1, refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 2), refcount(&game, "other_mask"));
}

test "assets: a reservoir whose mask never arrives still releases on removal" {
    // The asset table is the superset of the instance table — this entity
    // never had an instance for the reaper to find, but it does hold
    // catalog references.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.registerImageFromMemory("reservoir_mask", png_type, fake_png);
    const e = game.createEntity();
    try testing.expect(game.addPixelWater(e, .{
        .mask = "reservoir_mask",
        .logical_size = .{ 96, 18 },
    }));
    try testing.expect(game.waterInstance(e) == null);
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reservoir_mask"));

    game.removeComponent(e, PixelWater);
    engine.pixel_water_tick.tick(&game, 0);
    try testing.expectEqual(@as(u32, 0), refcount(&game, "reservoir_mask"));
}

test "assets: an ECS reset releases every reservoir's references" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    _ = try spawnReservoir(&game);
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));

    game.resetEcsBackend();
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
}

// ── Worlds ──────────────────────────────────────────────────────────────

test "world: a swap releases the instances and the return rebuilds them" {
    // A water-instance id belongs to the renderer that ISSUED it, and every
    // world owns its own renderer. Carrying the table across a swap hands
    // the incoming renderer ids it never issued.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("a");
    try game.setActiveWorld("a");
    const e = try spawnReservoir(&game);
    try testing.expect(game.waterInstance(e) != null);

    try game.createWorld("b");
    try game.setActiveWorld("b");
    // Released against the renderer that issued it, not carried over.
    try testing.expect(game.waterInstance(e) == null);

    try game.setActiveWorld("a");
    // The asset references were NOT dropped on the way out (the shelved
    // world's components still own them), so nothing has to re-acquire.
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
    game.tick(0);
    try testing.expect(game.waterInstance(e) != null);
    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());
}

test "world: a shelved world's asset references survive a tick in another world" {
    // The asset table deliberately SURVIVES a world swap (the shelved
    // world's components still own their references). That is only sound
    // if the reaper can tell the two worlds apart: keyed on `Entity`
    // alone, every shelved record looks like an orphan against the
    // newly-active ECS and gets released out from under a live component.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("a");
    try game.setActiveWorld("a");
    const e = try spawnReservoir(&game);
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));

    try game.createWorld("b");
    try game.setActiveWorld("b");
    // A single frame in the OTHER world must not touch world a's books.
    game.tick(0);
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reflection"));

    // And the reservoir still works on the way back — the references it
    // kept are the ones its instance is rebuilt from.
    try game.setActiveWorld("a");
    game.tick(0);
    try testing.expect(game.waterInstance(e) != null);
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
}

test "world: colliding entity ids get their own asset records" {
    // Two independent world ECS instances hand out the same ids from the
    // same base, so world b's first entity IS world a's first entity as
    // far as an `Entity`-keyed table is concerned.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("a");
    try game.setActiveWorld("a");
    const e_a = try spawnReservoir(&game);

    try game.createWorld("b");
    try game.setActiveWorld("b");
    const e_b = game.createEntity();
    // The premise: without it this test proves nothing.
    try testing.expectEqual(e_a, e_b);
    game.addSprite(e_b, .{ .sprite_name = "reservoir" });
    try testing.expect(game.addPixelWater(e_b, authored()));

    // Two reservoirs in two worlds → two references on top of the eager
    // load. A shared record would have mistaken b's reservoir for a's and
    // never acquired at all.
    try testing.expectEqual(@as(u32, 3), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 3), refcount(&game, "reflection"));

    // Destroying b's reservoir drops only b's reference.
    game.destroyEntity(e_b);
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reflection"));
}

// ── Validation ──────────────────────────────────────────────────────────

test "validation: a missing mask is rejected and names the field" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    var bad = authored();
    bad.mask = "";

    try testing.expect(!game.addPixelWater(e, bad));
    // Rejected BEFORE anything was committed: no component, no gfx call.
    try testing.expect(game.pixelWater(e) == null);
    try testing.expectEqual(@as(usize, 0), game.renderer.create_calls);

    const issue = engine.validatePixelWaterComponent(bad).?;
    try testing.expectEqual(engine.PixelWaterField.mask, issue.field);
    try testing.expectEqual(engine.PixelWaterReason.missing, issue.reason);
}

test "validation: every range / finiteness rule names its own field" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    const Case = struct {
        mutate: *const fn (*PixelWater) void,
        field: engine.PixelWaterField,
        reason: engine.PixelWaterReason,
    };

    const cases = [_]Case{
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.logical_size = .{ 0, 18 };
            }
        }.f, .field = .logical_size, .reason = .not_positive },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.grid_pixels = 0;
            }
        }.f, .field = .grid_pixels, .reason = .not_positive },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.water_level = nan;
            }
        }.f, .field = .water_level, .reason = .non_finite },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.water_level = 1.5;
            }
        }.f, .field = .water_level, .reason = .out_of_unit_range },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.deep_color = "not-a-colour";
            }
        }.f, .field = .deep_color, .reason = .invalid_hex },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.surface_color = "#12345";
            }
        }.f, .field = .surface_color, .reason = .invalid_hex },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.wave_amplitude_pixels = -1;
            }
        }.f, .field = .wave_amplitude_pixels, .reason = .negative },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.wave_period_seconds = 0;
            }
        }.f, .field = .wave_period_seconds, .reason = .not_positive },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.reflection_opacity = 1.5;
            }
        }.f, .field = .reflection_opacity, .reason = .out_of_unit_range },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.distortion_pixels = inf;
            }
        }.f, .field = .distortion_pixels, .reason = .non_finite },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.ripple_duration_seconds = 0;
            }
        }.f, .field = .ripple_duration_seconds, .reason = .not_positive },
        .{ .mutate = struct {
            fn f(c: *PixelWater) void {
                c.ripple_radius_pixels = -2;
            }
        }.f, .field = .ripple_radius_pixels, .reason = .not_positive },
    };

    for (cases) |c| {
        var comp = authored();
        c.mutate(&comp);
        const issue = engine.validatePixelWaterComponent(comp) orelse {
            std.debug.print("expected {s} to be rejected\n", .{@tagName(c.field)});
            return error.ExpectedRejection;
        };
        try testing.expectEqual(c.field, issue.field);
        try testing.expectEqual(c.reason, issue.reason);
    }

    // The unmutated reservoir is accepted — otherwise every case above would
    // pass for the wrong reason.
    try testing.expect(engine.validatePixelWaterComponent(authored()) == null);
}

// ── Bounded strength — BOTH boundaries ──────────────────────────────────

test "strength boundary 1 (authored): ripple_strength_pixels rejects negative and non-finite" {
    var negative = authored();
    negative.ripple_strength_pixels = -1;
    const a = engine.validatePixelWaterComponent(negative).?;
    try testing.expectEqual(engine.PixelWaterField.ripple_strength_pixels, a.field);
    try testing.expectEqual(engine.PixelWaterReason.negative, a.reason);

    var non_finite = authored();
    non_finite.ripple_strength_pixels = std.math.nan(f32);
    const b = engine.validatePixelWaterComponent(non_finite).?;
    try testing.expectEqual(engine.PixelWaterField.ripple_strength_pixels, b.field);
    try testing.expectEqual(engine.PixelWaterReason.non_finite, b.reason);

    // Above one is LEGAL here: the authored value is a pixel amplitude, not a
    // unit scale. Pinning that asymmetry is the point of having two
    // boundaries rather than one shared rule.
    var big = authored();
    big.ripple_strength_pixels = 4;
    try testing.expect(engine.validatePixelWaterComponent(big) == null);
}

test "strength boundary 2 (runtime): addWaterRipple rejects negative, >1 and non-finite" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);

    const before = game.renderer.ripple_calls;

    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, 10, -0.1));
    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, 10, 1.5));
    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, 10, std.math.nan(f32)));
    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, 10, std.math.inf(f32)));
    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, std.math.nan(f32), 0.5));

    // MECHANISM: none of those reached the renderer. Asserting only "the
    // ripple count did not grow" would also pass if the call had been
    // forwarded and gfx had silently ignored it.
    try testing.expectEqual(before, game.renderer.ripple_calls);

    // Both endpoints of the closed interval are accepted.
    try game.addWaterRipple(e, 10, 0);
    try game.addWaterRipple(e, 10, 1);
    try testing.expectEqual(before + 2, game.renderer.ripple_calls);
}

test "ripple: one drop crossing forwards exactly one impact" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);

    const before_calls = game.renderer.ripple_calls;
    const before_count = game.renderer.waterState(game.waterInstance(e).?).?.ripple_count;

    try game.addWaterRipple(e, 42, 0.8);

    try testing.expectEqual(before_calls + 1, game.renderer.ripple_calls);
    try testing.expectEqual(
        before_count + 1,
        game.renderer.waterState(game.waterInstance(e).?).?.ripple_count,
    );
}

test "ripple: out-of-bounds X and an empty reservoir are refused by gfx, not silently accepted" {
    // The engine delegates X bounds and the empty-reservoir rule; what it
    // owes the caller is that the refusal SURFACES as an error rather than
    // being swallowed.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);

    try testing.expectError(error.PixelWaterRejected, game.addWaterRipple(e, 96, 0.5));
    try testing.expectError(error.PixelWaterRejected, game.addWaterRipple(e, -1, 0.5));

    try game.setWaterLevel(e, 0);
    try testing.expectError(error.PixelWaterRejected, game.addWaterRipple(e, 10, 0.5));
}

// ── Stage before commit ─────────────────────────────────────────────────

test "stage-before-commit: engine-rejected settings leave BOTH sides on the previous values" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    const before_settings_calls = game.renderer.set_settings_calls;

    var bad = game.pixelWater(e).?.settings();
    bad.reflection_opacity = 9;
    try testing.expectError(error.InvalidPixelWater, game.setWaterSettings(e, bad));

    // Component side: previous value.
    try testing.expectApproxEqAbs(@as(f32, 0.25), game.pixelWater(e).?.reflection_opacity, 1e-6);
    // gfx side: previous value.
    try testing.expectApproxEqAbs(
        @as(f32, 0.25),
        game.renderer.waterState(id).?.config.reflection_opacity,
        1e-6,
    );
    // MECHANISM: the renderer was never even asked. Both value assertions
    // above would also hold if the candidate had been pushed and rejected
    // downstream — this is what distinguishes "staged" from "attempted".
    try testing.expectEqual(before_settings_calls, game.renderer.set_settings_calls);
}

test "stage-before-commit: a gfx-rejected candidate also leaves BOTH sides intact" {
    // The other rejection path: the engine's validation passes, the renderer's
    // does not. Committing the component first and synchronizing after would
    // leave the component ahead of the instance here — the exact torn state
    // the ordering rule exists to prevent.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    game.renderer.reject_settings = true;

    var next = game.pixelWater(e).?.settings();
    next.reflection_opacity = 0.9;
    next.wave_amplitude_pixels = 2;
    try testing.expectError(error.PixelWaterRejected, game.setWaterSettings(e, next));

    // MECHANISM: the renderer WAS asked (unlike the test above) and refused.
    try testing.expectEqual(@as(usize, 1), game.renderer.set_settings_calls);

    try testing.expectApproxEqAbs(@as(f32, 0.25), game.pixelWater(e).?.reflection_opacity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), game.pixelWater(e).?.wave_amplitude_pixels, 1e-6);
    const st = game.renderer.waterState(id).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), st.config.reflection_opacity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), st.config.wave_amplitude_pixels, 1e-6);
}

test "stage-before-commit: the LOADER path rolls back too" {
    // Hot reload / live prefab refresh route through the same synchronization
    // operation, so a rejected re-author must not leave the component ahead
    // of the instance either.
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    var bad = authored();
    bad.ripple_radius_pixels = -3;
    try testing.expect(!game.addPixelWater(e, bad));

    try testing.expectApproxEqAbs(@as(f32, 6), game.pixelWater(e).?.ripple_radius_pixels, 1e-6);
    try testing.expectApproxEqAbs(
        @as(f32, 6),
        game.renderer.waterState(id).?.config.ripple_radius_pixels,
        1e-6,
    );
}

test "settings: an accepted change commits to both sides; an equal one is a no-op" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    var next = game.pixelWater(e).?.settings();
    next.distortion_pixels = 0.5;
    try game.setWaterSettings(e, next);

    try testing.expectEqual(@as(usize, 1), game.renderer.set_settings_calls);
    try testing.expectApproxEqAbs(@as(f32, 0.5), game.pixelWater(e).?.distortion_pixels, 1e-6);
    try testing.expectApproxEqAbs(
        @as(f32, 0.5),
        game.renderer.waterState(id).?.config.distortion_pixels,
        1e-6,
    );

    // Re-applying the same value must not re-submit — a redundant material
    // write breaks the backend's draw batch.
    try game.setWaterSettings(e, next);
    try testing.expectEqual(@as(usize, 1), game.renderer.set_settings_calls);
}

test "settings: waves toggle without destroying the authored amplitude" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    try game.setWaterWavesEnabled(e, false);
    const st = game.renderer.waterState(id).?;
    try testing.expect(!st.config.waves_enabled);
    // The authored amplitude survives — the reason there is a flag at all.
    try testing.expectApproxEqAbs(@as(f32, 1), st.config.wave_amplitude_pixels, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), game.pixelWater(e).?.wave_amplitude_pixels, 1e-6);
}

test "level: NaN is rejected, out-of-range clamps, and both sides agree" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    const before = game.renderer.set_level_calls;
    try testing.expectError(error.InvalidPixelWater, game.setWaterLevel(e, std.math.nan(f32)));
    try testing.expectEqual(before, game.renderer.set_level_calls); // never forwarded
    try testing.expectApproxEqAbs(@as(f32, 0.35), game.pixelWater(e).?.water_level, 1e-6);

    try game.setWaterLevel(e, 1.8);
    try testing.expectApproxEqAbs(@as(f32, 1), game.pixelWater(e).?.water_level, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), game.renderer.waterState(id).?.level, 1e-6);
}

// ── Simulation time: pause and time scale ───────────────────────────────

test "time: the water clock advances on the engine's TIME-SCALED delta" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const id = game.waterInstance(e).?;

    game.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), game.renderer.waterState(id).?.time, 1e-6);

    // Hard pause (time_scale == 0): the clock HOLDS. A wall-clock
    // implementation would keep moving here, which is exactly what makes
    // this assertion load-bearing rather than decorative.
    const advance_calls_before_pause = game.renderer.advance_calls;
    game.pause();
    game.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), game.renderer.waterState(id).?.time, 1e-6);

    // MECHANISM: the tick still RAN while paused (so a mask finishing upload
    // behind a pause menu can still bind) — it simply advanced by zero. If
    // the phase had been skipped wholesale the time assertion above would
    // pass for the wrong reason.
    try testing.expect(game.renderer.advance_calls > advance_calls_before_pause);

    // Slow-mo: half rate.
    game.resume_();
    game.setTimeScale(0.5);
    game.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), game.renderer.waterState(id).?.time, 1e-6);
}

test "time: two reservoirs keep independent clocks" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const a = try spawnReservoir(&game);
    const b = game.createEntity();
    game.addSprite(b, .{ .sprite_name = "reservoir_b" });
    try testing.expect(game.addPixelWater(b, authored()));

    const id_a = game.waterInstance(a).?;
    const id_b = game.waterInstance(b).?;

    // Seed A's clock apart from B's BEFORE any tick. Equal starting times
    // would leave this test unable to tell two independent clocks from one
    // shared clock — and an implementation that advanced only B would pass
    // an assertion on B alone.
    try game.renderer.setWaterTime(id_a, 1.0);
    game.tick(0.25);
    try testing.expectApproxEqAbs(@as(f32, 1.25), game.renderer.waterState(id_a).?.time, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), game.renderer.waterState(id_b).?.time, 1e-6);

    // Then freeze A's entity out of the world and keep ticking.
    game.destroyEntity(a);
    game.tick(0.25);

    try testing.expectApproxEqAbs(@as(f32, 0.5), game.renderer.waterState(id_b).?.time, 1e-6);
    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());
}

// ── Colour ──────────────────────────────────────────────────────────────

test "colour: authored sRGB hex is converted to linear exactly once" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnReservoir(&game);
    const st = game.renderer.waterState(game.waterInstance(e).?).?;

    // `#172D36` → sRGB bytes 0x17/0x2D/0x36 → the sRGB EOTF.
    const expected_r = engine.srgbToLinear(0x17);
    try testing.expectApproxEqAbs(expected_r, st.config.deep.r, 1e-6);
    try testing.expectApproxEqAbs(engine.srgbToLinear(0x2D), st.config.deep.g, 1e-6);
    try testing.expectApproxEqAbs(engine.srgbToLinear(0x36), st.config.deep.b, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), st.config.deep.a, 1e-6);

    // Double-converting would land here instead — the assertion that makes
    // "converted once" a real claim rather than a comment.
    const double = engine.srgbToLinear(@intFromFloat(@round(expected_r * 255)));
    try testing.expect(@abs(double - st.config.deep.r) > 1e-4);

    // Alpha is coverage, not light: NOT gamma-decoded.
    try testing.expectApproxEqAbs(@as(f32, 1), st.config.highlight.a, 1e-6);
}

test "colour: hex parsing accepts #RRGGBB / #RRGGBBAA and rejects the rest" {
    const c = try engine.parseHexColor("#172D36");
    try testing.expectEqual(@as(u8, 0x17), c.r);
    try testing.expectEqual(@as(u8, 0x2D), c.g);
    try testing.expectEqual(@as(u8, 0x36), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);

    const d = try engine.parseHexColor("172D3680");
    try testing.expectEqual(@as(u8, 0x80), d.a);

    try testing.expectError(error.InvalidHexColor, engine.parseHexColor("#12345"));
    try testing.expectError(error.InvalidHexColor, engine.parseHexColor("#12345G"));
    try testing.expectError(error.InvalidHexColor, engine.parseHexColor(""));
}

// ── Public API reachability ─────────────────────────────────────────────

test "root API: PixelWater and its settings type are reachable through the engine root" {
    // A type that is not reachable from `src/root.zig` is not usable by a
    // game, however correct it is internally. This file imports ONLY
    // `engine`, so the test is the reachability proof.
    try testing.expect(engine.PixelWater == engine.pixel_water_mod.PixelWater);
    try testing.expect(engine.PixelWaterSettings == engine.pixel_water_mod.PixelWaterSettings);
    try testing.expect(engine.PixelWaterColor == engine.pixel_water_mod.PixelWaterColor);
    try testing.expect(engine.PixelWaterError == engine.pixel_water_mod.PixelWaterError);

    // And the component the engine hands the ECS is that very type.
    try testing.expect(TestGame.PixelWaterComp == engine.PixelWater);

    // A game can build a settings value from the public surface alone.
    const s: PixelWaterSettings = .{ .deep_color = "#101820", .reflection_opacity = 0.2 };
    try testing.expect(engine.validatePixelWaterSettings(s) == null);
}

// ── Live prefab refresh (#691) reaches the built-in ─────────────────────
//
// `PixelWater` is a JSONC BUILT-IN: `component_apply.zig` routes it before
// its registry loop, so it is deliberately absent from `Components.names()`.
// The prefab-refresh dispatcher iterates exactly that registry, which used to
// mean a pushed prefab's reservoir edit silently did NOTHING until a full
// respawn — component and gfx instance both left on the retired values. Codex
// P2 on #880.
//
// These assert the MECHANISM on BOTH sides: the live component AND the
// renderer state the instance actually holds. A test that only checked the
// component would pass on a fix that never reached gfx; one that only checked
// "no crash" would pass on the bug itself.

const Bridge = engine.JsoncSceneBridge(TestGame, EmptyComponents);

const reservoir_prefab_v1 =
    \\{ "components": {
    \\    "Sprite": { "sprite_name": "reservoir" },
    \\    "PixelWater": {
    \\      "mask": "reservoir_mask",
    \\      "reflection": "reflection",
    \\      "logical_size": [96, 18],
    \\      "grid_pixels": 1,
    \\      "water_level": 0.35,
    \\      "distortion_pixels": 1
    \\    }
    \\} }
;

/// Boot a bridge-backed game with the reservoir prefab installed, the two
/// textures already resident, and one live instance spawned.
fn bootRefresh(game: *TestGame) !MockEcs.Entity {
    try loadMask(game, "reservoir_mask");
    try loadMask(game, "reflection");
    try Bridge.addEmbeddedPrefab(game, "reservoir", reservoir_prefab_v1, "prefabs");
    try Bridge.loadSceneFromSource(game,
        \\{ "children": [] }
    , "prefabs");
    const e = game.spawnPrefab("reservoir", .{ .x = 0, .y = 0 }).?;
    // The push is only meaningful against a reservoir that is already fully
    // resolved on both sides.
    try testing.expect(game.waterInstance(e) != null);
    return e;
}

test "prefab refresh: a non-structural reservoir edit reaches the live component AND the gfx instance" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try bootRefresh(&game);
    const id = game.waterInstance(e).?;
    try testing.expectApproxEqAbs(@as(f32, 0.35), game.renderer.waterState(id).?.level, 1e-6);

    const settings_before = game.renderer.set_settings_calls;
    const level_before = game.renderer.set_level_calls;
    const releases_before = game.renderer.release_calls;

    try game.reloadPrefabSource("reservoir",
        \\{ "components": {
        \\    "Sprite": { "sprite_name": "reservoir" },
        \\    "PixelWater": {
        \\      "mask": "reservoir_mask",
        \\      "reflection": "reflection",
        \\      "logical_size": [96, 18],
        \\      "grid_pixels": 1,
        \\      "water_level": 0.8,
        \\      "distortion_pixels": 2
        \\    }
        \\} }
    );

    // The component took the new values…
    const comp = game.pixelWater(e).?;
    try testing.expectApproxEqAbs(@as(f32, 0.8), comp.water_level, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), comp.distortion_pixels, 1e-6);

    // …and so did the gfx instance. This is the half the bug dropped.
    try testing.expectEqual(id.index, game.waterInstance(e).?.index);
    const st = game.renderer.waterState(id).?;
    try testing.expectApproxEqAbs(@as(f32, 0.8), st.level, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), st.config.distortion_pixels, 1e-6);

    // WHICH PATH RAN: the validated non-structural writes, not a
    // drop-and-recreate (which would reach the same values by accident).
    try testing.expect(game.renderer.set_settings_calls > settings_before);
    try testing.expect(game.renderer.set_level_calls > level_before);
    try testing.expectEqual(releases_before, game.renderer.release_calls);
}

test "prefab refresh: a structural reservoir edit recreates the instance from the new component" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try bootRefresh(&game);
    const old_id = game.waterInstance(e).?;
    const releases_before = game.renderer.release_calls;

    try game.reloadPrefabSource("reservoir",
        \\{ "components": {
        \\    "Sprite": { "sprite_name": "reservoir" },
        \\    "PixelWater": {
        \\      "mask": "reservoir_mask",
        \\      "reflection": "reflection",
        \\      "logical_size": [64, 18],
        \\      "grid_pixels": 1,
        \\      "water_level": 0.35,
        \\      "distortion_pixels": 1
        \\    }
        \\} }
    );

    // Structural fields are the instance's identity: the old one is gone…
    try testing.expectEqual(releases_before + 1, game.renderer.release_calls);
    // …and the tick rebuilds it from the new component.
    engine.pixel_water_tick.tick(&game, 0);
    const new_id = game.waterInstance(e).?;
    try testing.expect(game.renderer.waterState(old_id) == null);
    try testing.expectEqual(@as(u32, 64), game.renderer.waterState(new_id).?.config.logical_width);
    try testing.expectEqual(@as(usize, 1), game.renderer.waterInstanceCount());
}

test "prefab refresh: dropping the reservoir from the prefab removes the component, the instance and the asset refs" {
    installImageBackend();
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = try bootRefresh(&game);
    const id = game.waterInstance(e).?;
    // The reservoir is pinning both textures on top of the loader's own ref.
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 2), refcount(&game, "reflection"));

    try game.reloadPrefabSource("reservoir",
        \\{ "components": { "Sprite": { "sprite_name": "reservoir" } } }
    );

    try testing.expect(game.pixelWater(e) == null);
    try testing.expect(game.waterInstance(e) == null);
    try testing.expect(game.renderer.waterState(id) == null);
    try testing.expectEqual(@as(usize, 0), game.renderer.waterInstanceCount());
    // Released SYNCHRONOUSLY — not left for a tick that a reservoir-less
    // world has no reason to run.
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reservoir_mask"));
    try testing.expectEqual(@as(u32, 1), refcount(&game, "reflection"));
}

// ── Graceful degrade on a renderer without the water seam ───────────────

const NoWaterGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

test "degrade: a renderer without the water seam still compiles and runs" {
    // `core.StubRender` has no `createWaterInstance`. The whole side-table and
    // every helper must fold to a no-op rather than a type error — compiling
    // this test at all is half the assertion.
    var game = NoWaterGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    try testing.expect(game.addPixelWater(e, authored()));
    try testing.expect(game.pixelWater(e) != null);
    try testing.expect(game.waterInstance(e) == null);

    // Validation still applies; the runtime path reports "no instance".
    try testing.expectError(error.PixelWaterRejected, game.addWaterRipple(e, 10, 0.5));
    try testing.expectError(error.InvalidPixelWater, game.addWaterRipple(e, 10, 2));

    // Settings still commit to the component (the authored fallback sprite
    // is what draws), and the tick is inert.
    var next = game.pixelWater(e).?.settings();
    next.distortion_pixels = 0.25;
    try game.setWaterSettings(e, next);
    try testing.expectApproxEqAbs(@as(f32, 0.25), game.pixelWater(e).?.distortion_pixels, 1e-6);

    game.tick(0.5);
}
