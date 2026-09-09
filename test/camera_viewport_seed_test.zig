//! Camera-bound layers Phase 2 (#761): `seedCameraFromComponent` carries an
//! authored `Camera.viewport` through to the live renderer camera's
//! `screen_viewport`, which the gfx render loop's per-camera `applyViewport`
//! then hands to the backend's `setViewport`. Verified here on the
//! single-camera (non-tagged-manager) seed path with a minimal camera-capable
//! recording renderer whose `CameraType` carries a `screen_viewport` field.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const MockEcs = engine.MockEcsBackend(u32);

/// Renderer with a settable single camera whose `CameraType` exposes a
/// `screen_viewport` field (like the gfx camera). `CameraManagerType = void`
/// so the engine takes the single-camera fallback seed path.
fn CamRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) { rectangle: struct { width: f32 = 10, height: f32 = 10 } } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        const ScreenVP = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };
        pub const CameraType = struct {
            x: f32 = 0,
            y: f32 = 0,
            zoom: f32 = 1,
            screen_viewport: ?ScreenVP = null,
            pub fn setPosition(s: *@This(), x: f32, y: f32) void {
                s.x = x;
                s.y = y;
            }
            pub fn setZoom(s: *@This(), z: f32) void {
                s.zoom = z;
            }
        };
        pub const CameraManagerType = void;

        camera: CameraType = .{},

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn getCamera(self: *Self) *CameraType {
            return &self.camera;
        }

        pub fn trackEntity(_: *Self, _: Entity, _: core.render.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
        pub fn render(_: *Self) void {}
        pub fn clear(_: *Self) void {}
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

fn CamGame() type {
    return engine.GameConfig(
        CamRender(u32),
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
    );
}

test "seedCameraFromComponent copies an authored Camera.viewport to the renderer camera" {
    const G = CamGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 3, .y = 4 });
    game.addComponent(e, engine.Camera{
        .zoom = 2,
        .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 300 },
    });

    game.seedCameraFromComponent();

    const cam = game.getCamera();
    // Transform seeded as before.
    try testing.expectEqual(@as(f32, 3), cam.x);
    try testing.expectEqual(@as(f32, 2), cam.zoom);
    // Authored viewport reached the renderer camera's screen_viewport (#761).
    try testing.expect(cam.screen_viewport != null);
    try testing.expectEqual(@as(i32, 400), cam.screen_viewport.?.width);
    try testing.expectEqual(@as(i32, 300), cam.screen_viewport.?.height);
}

test "a Camera with no viewport clears the renderer camera's screen_viewport" {
    const G = CamGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    // Pre-set a stale viewport on the camera to prove the seed clears it.
    game.getCamera().screen_viewport = .{ .x = 1, .y = 2, .width = 9, .height = 9 };

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addComponent(e, engine.Camera{ .zoom = 1 }); // viewport = null

    game.seedCameraFromComponent();

    try testing.expect(game.getCamera().screen_viewport == null);
}
