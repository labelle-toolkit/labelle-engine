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

test "y_axis: GameConfig (positional) defaults to .down" {
    // The historical positional entry point the assembler still emits must
    // default to the RFC's screen-native convention.
    try testing.expectEqual(core.YAxis.down, engine.Game.y_axis);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try testing.expectEqual(core.YAxis.down, game.yAxis());
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
