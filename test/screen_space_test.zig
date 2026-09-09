//! Tests for the screen coordinate-space accessors (labelle-engine#852).
//!
//! `getMouseX`/`getMouseY` report the BACKEND's own space, and that space
//! is not uniform across backends: bgfx / wgpu / sokol scale the cursor to
//! physical framebuffer pixels (2x the window on a Retina display), while
//! raylib / SDL report logical window points. Everything a game *draws* —
//! sprite `Position`, `drawGizmoRectScreen`, the project's declared
//! `.width`/`.height` — is in the design/logical space, so raw
//! `getMouseX/Y` cannot be hit-tested against drawn content portably.
//!
//! The fix is additive: `getMouseDesign` / `getMouseLogical` deliver the
//! cursor already mapped through the backend's own `screenToDesign`, and
//! `designToScreen` / `logicalToScreen` map back. `framebufferSize` /
//! `designSize` expose the two sizes for games that want the raw numbers,
//! and report `null` rather than a lie on a renderer that doesn't have
//! them.
//!
//! Three renderer shapes are driven here, mirroring the real backend
//! spread:
//!
//!   HiDpiRenderer — a 2x framebuffer (1600x1200 physical, 800x600
//!                   design), like bgfx / wgpu / sokol on Retina.
//!   OneToOneRenderer — a 1x framebuffer (800x600 both ways), like the
//!                   same backends on a non-HiDPI display.
//!   BareRenderer  — implements only the passthrough `screenToDesign`,
//!                   with none of the new decls, like raylib / SDL. The
//!                   `@hasDecl` guards must keep it compiling and give it
//!                   sane passthrough / `null` answers.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

// ── Controllable input stub ────────────────────────────────────────────
//
// Reports the cursor in the backend's PHYSICAL space, exactly as the real
// backends do. State is process-global because the interface dispatches to
// *type* decls, not an instance.
const MouseInput = struct {
    var x: f32 = 0;
    var y: f32 = 0;

    fn at(px: f32, py: f32) void {
        x = px;
        y = py;
    }

    pub fn isKeyDown(_: u32) bool {
        return false;
    }
    pub fn isKeyPressed(_: u32) bool {
        return false;
    }
    pub fn getMouseX() f32 {
        return x;
    }
    pub fn getMouseY() f32 {
        return y;
    }
};

// ── Renderer shapes ────────────────────────────────────────────────────

/// A stub renderer that DOES model the design/physical split, like the
/// bgfx / wgpu / sokol backends. `scale` is the physical/design ratio.
fn ScaledRenderer(
    comptime Entity: type,
    comptime scale: f32,
    comptime design_w: f32,
    comptime design_h: f32,
) type {
    return struct {
        const Self = @This();

        pub const ScreenPoint = struct { x: f32, y: f32 };
        pub const Size = struct { width: f32, height: f32 };

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

        screen_height: f32 = design_h,

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

        /// Physical framebuffer pixels → design pixels. The real backends
        /// go through NDC (so letterbox bars are handled); a uniform scale
        /// is enough to pin the engine-side wiring.
        pub fn screenToDesign(_: *const Self, px: f32, py: f32) ScreenPoint {
            return .{ .x = px / scale, .y = py / scale };
        }

        pub fn designToPhysical(_: *const Self, dx: f32, dy: f32) ScreenPoint {
            return .{ .x = dx * scale, .y = dy * scale };
        }

        pub fn framebufferSize(_: *const Self) Size {
            return .{ .width = design_w * scale, .height = design_h * scale };
        }

        pub fn designSize(_: *const Self) Size {
            return .{ .width = design_w, .height = design_h };
        }
    };
}

fn HiDpiRenderer(comptime Entity: type) type {
    return ScaledRenderer(Entity, 2.0, 800, 600);
}

fn OneToOneRenderer(comptime Entity: type) type {
    return ScaledRenderer(Entity, 1.0, 800, 600);
}

/// raylib / SDL shape: a passthrough `screenToDesign` and NONE of the new
/// decls (`designToPhysical`, `framebufferSize`, `designSize`). Exercises
/// every `@hasDecl` fallback — this shape must still compile.
fn BareRenderer(comptime Entity: type) type {
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

        /// Backends with no design/physical distinction return the input
        /// unchanged — their input is already in the drawn space.
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

fn GameOn(comptime Renderer: fn (comptime type) type, comptime y_axis: core.YAxis) type {
    return engine.GameConfigWithYAxis(
        Renderer(MockEcs.Entity),
        MockEcs,
        MouseInput,
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

const HiDpiGame = GameOn(HiDpiRenderer, .down);
const HiDpiUpGame = GameOn(HiDpiRenderer, .up);
const OneToOneGame = GameOn(OneToOneRenderer, .down);
const BareGame = GameOn(BareRenderer, .down);

// ── getMouseDesign: the 2x case (the #852 reproduction) ────────────────

test "getMouseDesign undoes a 2x framebuffer; raw getMouseX does not" {
    var game = HiDpiGame.init(testing.allocator);
    defer game.deinit();

    // The user clicked the middle of an 800x600 window. A 2x backend
    // reports it at (800, 600) in framebuffer pixels.
    MouseInput.at(800, 600);

    // Raw accessors keep the backend's own space — unchanged by this fix,
    // so games that already compensate are not broken.
    try testing.expectEqual(@as(f32, 800), game.getMouseX());
    try testing.expectEqual(@as(f32, 600), game.getMouseY());

    // The new accessor lands on the design pixel the sprite was drawn at.
    const d = game.getMouseDesign();
    try testing.expectEqual(@as(f32, 400), d.x);
    try testing.expectEqual(@as(f32, 300), d.y);
}

test "getMouseDesign is the identity on a 1x framebuffer" {
    var game = OneToOneGame.init(testing.allocator);
    defer game.deinit();

    MouseInput.at(123, 45);
    const d = game.getMouseDesign();
    try testing.expectEqual(@as(f32, 123), d.x);
    try testing.expectEqual(@as(f32, 45), d.y);
}

test "getMouseDesign passes through on a renderer without the new decls" {
    // raylib / SDL shape: input is already logical, `screenToDesign` is a
    // passthrough, and nothing must fail to compile.
    var game = BareGame.init(testing.allocator);
    defer game.deinit();

    MouseInput.at(123, 45);
    const d = game.getMouseDesign();
    try testing.expectEqual(@as(f32, 123), d.x);
    try testing.expectEqual(@as(f32, 45), d.y);
}

// ── getMouseLogical: design + the y_axis convention ────────────────────

test "getMouseLogical under .down equals getMouseDesign" {
    var game = HiDpiGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(600);

    MouseInput.at(800, 600);
    const d = game.getMouseDesign();
    const l = game.getMouseLogical();
    try testing.expectEqual(d.x, l.x);
    try testing.expectEqual(d.y, l.y);
}

test "getMouseLogical under .up flips Y against the design height" {
    var game = HiDpiUpGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(600);

    // Framebuffer (800, 120) → design (400, 60) → logical (400, 540).
    // Note the flip uses the DESIGN height, not the framebuffer height —
    // which is exactly what a game that guessed a scale factor gets wrong.
    MouseInput.at(800, 120);
    const l = game.getMouseLogical();
    try testing.expectEqual(@as(f32, 400), l.x);
    try testing.expectEqual(@as(f32, 540), l.y);
}

// ── The inverse mapping ────────────────────────────────────────────────

test "designToScreen inverts screenToDesign on a 2x framebuffer" {
    var game = HiDpiGame.init(testing.allocator);
    defer game.deinit();

    const p = game.designToScreen(400, 300);
    try testing.expectEqual(@as(f32, 800), p.x);
    try testing.expectEqual(@as(f32, 600), p.y);

    const back = game.screenToDesign(p.x, p.y);
    try testing.expectEqual(@as(f32, 400), back.x);
    try testing.expectEqual(@as(f32, 300), back.y);
}

test "designToScreen is a passthrough when the renderer omits designToPhysical" {
    var game = BareGame.init(testing.allocator);
    defer game.deinit();

    const p = game.designToScreen(400, 300);
    try testing.expectEqual(@as(f32, 400), p.x);
    try testing.expectEqual(@as(f32, 300), p.y);
}

test "logicalToScreen round-trips getMouseLogical under .up" {
    var game = HiDpiUpGame.init(testing.allocator);
    defer game.deinit();
    game.setScreenHeight(600);

    MouseInput.at(800, 120);
    const l = game.getMouseLogical();
    const p = game.logicalToScreen(l.x, l.y);
    try testing.expectEqual(@as(f32, 800), p.x);
    try testing.expectEqual(@as(f32, 120), p.y);
}

// ── The size accessors ─────────────────────────────────────────────────

test "framebufferSize and designSize differ by the DPI scale on a 2x backend" {
    var game = HiDpiGame.init(testing.allocator);
    defer game.deinit();

    const fb = game.framebufferSize() orelse return error.TestExpectedFramebufferSize;
    const ds = game.designSize() orelse return error.TestExpectedDesignSize;

    try testing.expectEqual(@as(f32, 1600), fb.width);
    try testing.expectEqual(@as(f32, 1200), fb.height);
    try testing.expectEqual(@as(f32, 800), ds.width);
    try testing.expectEqual(@as(f32, 600), ds.height);
    try testing.expectEqual(@as(f32, 2), fb.width / ds.width);
}

test "framebufferSize equals designSize on a 1x backend" {
    var game = OneToOneGame.init(testing.allocator);
    defer game.deinit();

    const fb = game.framebufferSize() orelse return error.TestExpectedFramebufferSize;
    const ds = game.designSize() orelse return error.TestExpectedDesignSize;
    try testing.expectEqual(ds.width, fb.width);
    try testing.expectEqual(ds.height, fb.height);
}

test "size accessors report null (not a lie) when the renderer omits them" {
    var game = BareGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.framebufferSize() == null);
    try testing.expect(game.designSize() == null);
}

test "ScreenSize is re-exported from the engine root" {
    const s: engine.ScreenSize = .{ .width = 1600, .height = 1200 };
    try testing.expectEqual(@as(f32, 1600), s.width);
    try testing.expectEqual(@as(f32, 1200), s.height);
}
