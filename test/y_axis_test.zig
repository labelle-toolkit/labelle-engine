//! Tests for the project Y-axis convention (labelle-engine#639, RFC §3):
//! the `Game.y_axis` comptime constant, the `game.yAxis()` accessor, the
//! `.y_axis` default (`.down`), and the additive `screenToLogical` picking
//! path (Q1→(b), Q3) — including the invariant that raw `screenToDesign`
//! is *unchanged* by the convention.
//!
//! Uses a local `HeightRenderer` (mirroring `set_sprite_flip_test`'s
//! `FlipRenderer`) so `screenToLogical` has a real `screen_height` to flip
//! against without dragging in a graphics backend. The default `Game`
//! (StubRender) covers the default-convention assertion.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

/// Minimal renderer that carries a `screen_height` field (settable via
/// `setScreenHeight`) and a passthrough `screenToDesign`/`ScreenPoint` — the
/// two surfaces `screenToLogical` composes. Everything else is a stub.
fn HeightRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const ScreenPoint = struct { x: f32, y: f32 };

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        screen_height: f32 = 600,

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
        pub fn setScreenHeight(self: *Self, h: f32) void {
            self.screen_height = h;
        }
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
        /// Raw passthrough — backends without a design/physical distinction
        /// return the input unchanged. `screenToLogical` then layers the
        /// `.y_axis` transform on top of this.
        pub fn screenToDesign(_: *const Self, px: f32, py: f32) ScreenPoint {
            return .{ .x = px, .y = py };
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

fn GameOn(comptime y_axis: core.YAxis) type {
    return engine.GameConfigWithYAxis(
        HeightRenderer(MockEcs.Entity),
        MockEcs,
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        engine.StubLogSink,
        EmptyComponents,
        &.{},
        void,
        y_axis,
    );
}

const DownGame = GameOn(.down);
const UpGame = GameOn(.up);

test "y_axis: GameConfig (positional) defaults to .up (#642 transition safety)" {
    // #642 made the renderer *read* Game.y_axis. The historical positional
    // entry point the assembler still emits must therefore fall back to `.up`
    // (today's flip) — an old-assembler game calls GameConfig with no axis, and
    // `.down` would stop the renderer flipping and render the game upside-down.
    // `.down` stays the *project-config* default (assembler/labelle-init), not
    // the engine code default.
    try testing.expectEqual(core.YAxis.up, engine.Game.y_axis);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try testing.expectEqual(core.YAxis.up, game.yAxis());
}

test "y_axis: comptime constant and yAxis() accessor agree" {
    try testing.expectEqual(core.YAxis.down, DownGame.y_axis);
    try testing.expectEqual(core.YAxis.up, UpGame.y_axis);

    var down = DownGame.init(testing.allocator);
    defer down.deinit();
    var up = UpGame.init(testing.allocator);
    defer up.deinit();

    try testing.expectEqual(core.YAxis.down, down.yAxis());
    try testing.expectEqual(core.YAxis.up, up.yAxis());
}

test "screenToDesign stays RAW under both conventions (unchanged)" {
    // The whole point of Q1→(b): existing games keep using raw screenToDesign,
    // and it must be identical regardless of .y_axis.
    var down = DownGame.init(testing.allocator);
    defer down.deinit();
    var up = UpGame.init(testing.allocator);
    defer up.deinit();
    down.setScreenHeight(600);
    up.setScreenHeight(600);

    const d = down.screenToDesign(120, 50);
    const u = up.screenToDesign(120, 50);
    try testing.expectEqual(@as(f32, 120), d.x);
    try testing.expectEqual(@as(f32, 50), d.y);
    try testing.expectEqual(@as(f32, 120), u.x);
    try testing.expectEqual(@as(f32, 50), u.y); // raw, NOT flipped
}

test "screenToLogical under .down is the identity (== screenToDesign)" {
    var game = DownGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(600);

    const p = game.screenToLogical(120, 50);
    try testing.expectEqual(@as(f32, 120), p.x);
    try testing.expectEqual(@as(f32, 50), p.y); // y-down: no flip
}

test "screenToLogical under .up flips Y (height - y), x untouched" {
    var game = UpGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(600);

    // A click near the TOP of the window (small screen y) must yield a LARGE
    // logical y — the space where a y-up entity placed there actually sits.
    const top = game.screenToLogical(120, 50);
    try testing.expectEqual(@as(f32, 120), top.x);
    try testing.expectEqual(@as(f32, 550), top.y); // 600 - 50

    // A click near the BOTTOM yields a small logical y.
    const bottom = game.screenToLogical(120, 550);
    try testing.expectEqual(@as(f32, 50), bottom.y); // 600 - 550
}

test "screenToLogical matches core.screenToLogicalY exactly (no duplicated transform)" {
    var game = UpGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(480);

    const py: f32 = 137;
    const p = game.screenToLogical(0, py);
    const expected = core.screenToLogicalY(.up, py, 480);
    try testing.expectEqual(expected, p.y);
}

test "screenToLogical round-trips through the renderer's set height" {
    // Honours setScreenHeight rather than a baked-in default.
    var game = UpGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(1000);

    const p = game.screenToLogical(0, 300);
    try testing.expectEqual(@as(f32, 700), p.y); // 1000 - 300
}

// ───────────────────────────────────────────────────────────────────────────
// #642 — engine↔gfx renderer integration.
//
// The codegen template now instantiates `gfx.GfxRendererWith(.., Game.y_axis)`
// (output flip) alongside `engine.GameConfigWithYAxis(.., Game.y_axis)` (input
// picking), so the two paths read ONE axis. The engine crate doesn't depend on
// gfx, so these tests assert against `core.toScreenY` — the exact transform the
// gfx renderer applies on the way out (`renderer.zig` calls
// `core.toScreenY(y_axis, y, screen_height)`). That makes the engine the
// authority on the value of `Game.y_axis` that flows into the renderer.
// ───────────────────────────────────────────────────────────────────────────

/// The renderer's vertical mapping for a given Game, computed exactly as
/// `GfxRendererWith(.., Game.y_axis)` does — `core.toScreenY` over the height.
fn rendererScreenY(comptime G: type, logical_y: f32, height: f32) f32 {
    return core.toScreenY(G.y_axis, logical_y, height);
}

test "#642: default GameConfig renderer flip is bit-identical to pre-#642 (.up regression)" {
    // Pre-#642 the template hardcoded `gfx.GfxRenderer` (the `.up` alias), so
    // the flip was always `height - y`. The default `engine.Game` (positional
    // GameConfig, no axis) must reproduce that exactly — a known logical→screen
    // mapping. Anything else means an old-assembler game renders upside-down.
    try testing.expectEqual(core.YAxis.up, engine.Game.y_axis);

    const h: f32 = 600;
    // A y-up entity at logical y=50 (near the BOTTOM) renders near the bottom
    // of the screen: screen_y = 600 - 50 = 550.
    try testing.expectEqual(@as(f32, 550), rendererScreenY(engine.Game, 50, h));
    // A y-up entity at logical y=550 (near the TOP) renders near the top: 50.
    try testing.expectEqual(@as(f32, 50), rendererScreenY(engine.Game, 550, h));
    // Origin maps to the full height (bottom edge).
    try testing.expectEqual(@as(f32, 600), rendererScreenY(engine.Game, 0, h));
}

test "#642: .up renderer flip equals UpGame and equals the historic alias mapping" {
    // The explicit-.up path and the default path agree, and both equal the
    // raw pre-#642 `height - y`.
    const h: f32 = 480;
    inline for (.{ engine.Game, UpGame }) |G| {
        try testing.expectEqual(@as(f32, h - 137), rendererScreenY(G, 137, h));
    }
}

test "#642: GameConfigWithYAxis(.., .down) renderer is identity (no flip)" {
    // A project that emits `.down` gets an identity renderer transform — the
    // gfx renderer applies no flip, matching screen-native placement.
    const h: f32 = 600;
    try testing.expectEqual(@as(f32, 50), rendererScreenY(DownGame, 50, h));
    try testing.expectEqual(@as(f32, 550), rendererScreenY(DownGame, 550, h));
    try testing.expectEqual(@as(f32, 0), rendererScreenY(DownGame, 0, h));
}

test "#642: renderer output and screenToLogical input agree (round-trip), both axes" {
    // The whole point of #642 (gfx#276 Q2): output flip and input picking read
    // the SAME axis, so picking a rendered point round-trips back to the
    // logical coordinate. Render logical y -> screen_y, then screenToLogical
    // it back -> must equal the original logical y. Holds under both axes.
    var up = UpGame.init(testing.allocator);
    defer up.deinit();
    var down = DownGame.init(testing.allocator);
    defer down.deinit();
    up.setScreenHeight(720);
    down.setScreenHeight(720);

    const logical_ys = [_]f32{ 0, 137, 360, 700, 720 };
    inline for (.{ .{ &up, UpGame }, .{ &down, DownGame } }) |pair| {
        const game = pair[0];
        const G = pair[1];
        for (logical_ys) |ly| {
            const screen_y = rendererScreenY(G, ly, 720);
            const back = game.screenToLogical(0, screen_y);
            try testing.expectEqual(ly, back.y);
        }
    }
}
