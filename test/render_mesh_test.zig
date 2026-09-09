//! Render-phase custom-mesh seam (labelle-gfx#290 Stage 4).
//!
//! Covers the two halves of the seam the future `labelle-spine` plugin uses:
//!   1. `game.drawMesh(...)` — a public Game method that forwards a textured
//!      triangle mesh to the renderer's optional `drawMesh`, gated on
//!      `@hasDecl` so it is a no-op on renderers/backends without it.
//!   2. `SystemRegistry.renderMeshes(&game)` — the render-phase plugin
//!      callback: a plugin exports `Systems.renderMeshes(game)` which
//!      iterates its own components and calls `game.drawMesh(...)`.
//!
//! Both are asserted headlessly via a recording renderer that stands in for
//! the mock backend — it records each `drawMesh` call plus whether it landed
//! after the world sprite pass (`render()`), i.e. genuinely in the render
//! phase.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");
const BlendMode = core.BlendMode;

const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubVideo = engine.StubVideo;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;
const SystemRegistry = engine.SystemRegistry;

/// A renderer that satisfies the engine's RenderInterface (mirrors
/// `StubRender`) but additionally records `drawMesh` submissions — standing
/// in for the mock/gfx backend so the render-phase seam is testable headless.
fn RecordingRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) {
                rectangle: struct { width: f32 = 10, height: f32 = 10 },
                circle: struct { radius: f32 = 10 },
            } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        const MeshCall = struct {
            texture_id: u32,
            vertex_count: usize,
            index_count: usize,
            blend: BlendMode,
            /// True when the world sprite pass (`render()`) had already run
            /// this frame — proves the mesh was submitted in the render phase.
            after_render: bool,
        };

        render_count: usize = 0,
        mesh_calls: std.ArrayListUnmanaged(MeshCall) = .empty,
        alloc: std.mem.Allocator = undefined,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .alloc = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.mesh_calls.deinit(self.alloc);
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

        pub fn render(self: *Self) void {
            self.render_count += 1;
        }
        pub fn clear(self: *Self) void {
            self.render_count = 0;
        }

        /// The optional textured-mesh primitive. Records the call.
        pub fn drawMesh(
            self: *Self,
            texture_id: u32,
            positions: []const f32,
            _: []const f32,
            _: []const u32,
            indices: []const u16,
            blend: BlendMode,
        ) void {
            self.mesh_calls.append(self.alloc, .{
                .texture_id = texture_id,
                .vertex_count = positions.len / 2,
                .index_count = indices.len,
                .blend = blend,
                .after_render = self.render_count > 0,
            }) catch {};
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

fn RecordingGame() type {
    return GameConfig(
        RecordingRender(u32),
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void, // Hooks
        StubLogSink,
        EmptyComponents,
        &.{}, // gizmo categories
        void, // game events
    );
}

// A stand-in `labelle-spine`-style plugin: its render-phase callback iterates
// its (here, hard-coded) meshes and submits each via `game.drawMesh(...)`.
const FakeMeshPlugin = struct {
    pub const Systems = struct {
        // One unit quad: 4 verts, 2 triangles.
        const positions = [_]f32{ 0, 0, 10, 0, 10, 10, 0, 10 };
        const uvs = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 1 };
        const colors = [_]u32{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff };
        const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

        pub fn renderMeshes(game: anytype) void {
            game.drawMesh(77, &positions, &uvs, &colors, &indices, .additive);
        }
    };
};

test "drawMesh forwards a textured mesh to the renderer" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    const pos = [_]f32{ 0, 0, 1, 0, 1, 1 }; // 3 verts
    const uv = [_]f32{ 0, 0, 1, 0, 1, 1 };
    const col = [_]u32{ 0, 0, 0 };
    const idx = [_]u16{ 0, 1, 2 }; // 1 triangle

    game.drawMesh(42, &pos, &uv, &col, &idx, .normal);

    const calls = game.renderer.mesh_calls.items;
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqual(@as(u32, 42), calls[0].texture_id);
    try testing.expectEqual(@as(usize, 3), calls[0].vertex_count);
    try testing.expectEqual(@as(usize, 3), calls[0].index_count);
    try testing.expectEqual(BlendMode.normal, calls[0].blend);
}

test "SystemRegistry.renderMeshes drives a plugin drawMesh in the render phase" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    const PluginSystems = SystemRegistry(.{FakeMeshPlugin});

    // Mirror the generated render sequence: world sprite pass, then the
    // render-phase mesh callbacks composite over it.
    game.render();
    PluginSystems.renderMeshes(&game);

    const calls = game.renderer.mesh_calls.items;
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqual(@as(u32, 77), calls[0].texture_id);
    try testing.expectEqual(@as(usize, 4), calls[0].vertex_count); // quad
    try testing.expectEqual(@as(usize, 6), calls[0].index_count); // 2 tris
    try testing.expectEqual(BlendMode.additive, calls[0].blend);
    // The mesh landed after render() — i.e. genuinely in the render phase.
    try testing.expect(calls[0].after_render);
}

test "renderMeshes is a comptime no-op when no plugin declares it" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    // A plugin that exports Systems but no renderMeshes must be skipped.
    const NoMeshPlugin = struct {
        pub const Systems = struct {
            pub fn tick(_: anytype, _: f32) void {}
        };
    };
    const PluginSystems = SystemRegistry(.{NoMeshPlugin});

    game.render();
    PluginSystems.renderMeshes(&game);

    try testing.expectEqual(@as(usize, 0), game.renderer.mesh_calls.items.len);
}

test "drawMesh is a no-op on a renderer without drawMesh (back-compat)" {
    // The default engine.Game uses StubRender, which has no `drawMesh` — the
    // call must compile and do nothing (zero-cost, non-breaking).
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    const pos = [_]f32{ 0, 0, 1, 0, 1, 1 };
    const uv = [_]f32{ 0, 0, 1, 0, 1, 1 };
    const col = [_]u32{ 0, 0, 0 };
    const idx = [_]u16{ 0, 1, 2 };
    game.drawMesh(1, &pos, &uv, &col, &idx, .normal); // no crash, no effect
}
