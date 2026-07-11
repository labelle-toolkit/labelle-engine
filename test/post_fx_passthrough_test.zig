//! Post-fx stack passthrough + type re-export (labelle-gfx#305 Phase 2 Slice C).
//!
//! Three things under test:
//!   1. The engine surfaces the post-fx VALUE TYPES (`engine.PostPass` /
//!      `PostPassKind` / `PostPassUniforms`) and they are the SAME core types
//!      gfx re-exports — proving the diamond stays unified (the engine takes no
//!      gfx module dependency; the types come from labelle-core).
//!   2. A `PostPass` literal built through the engine surface round-trips its
//!      uniform fields, so a game / assembler-generated main.zig can seed the
//!      `.post_fx` stack via `engine.PostPass{ ... }`.
//!   3. The actual `Game` forwarding seam: `Game.setPostFx` / `pushPostPass` /
//!      `clearPostFx` reach `renderer.inner.<method>` when the renderer wraps a
//!      gfx-shaped retained engine (the `GfxEngineType`/`inner` structure the
//!      mixin's `@hasDecl` guard keys off), and compile to safe no-ops when it
//!      does not (older gfx / StubRender / mock).

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");

const PostPass = core.backend_contract.PostPass;
const PostPassKind = core.backend_contract.PostPassKind;

const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubVideo = engine.StubVideo;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;

test "engine re-exports the labelle-core post-fx types (unified diamond)" {
    // Identity, not just structural equality: the engine surface hands back the
    // exact core types gfx also re-exports, so values flow across the seam.
    try testing.expect(engine.PostPass == core.backend_contract.PostPass);
    try testing.expect(engine.PostPassKind == core.backend_contract.PostPassKind);
    try testing.expect(engine.PostPassUniforms == core.backend_contract.PostPassUniforms);
}

test "PostPass literal built via the engine surface round-trips its uniforms" {
    const pass = engine.PostPass{
        .kind = .vignette,
        .uniforms = .{ .scalar0 = 0.8, .scalar1 = 0.5, .r = 0.1, .g = 0.2, .b = 0.3 },
    };

    try testing.expectEqual(engine.PostPassKind.vignette, pass.kind);
    try testing.expectEqual(@as(f32, 0.8), pass.uniforms.scalar0);
    try testing.expectEqual(@as(f32, 0.5), pass.uniforms.scalar1);
    try testing.expectEqual(@as(f32, 0.1), pass.uniforms.r);
    try testing.expectEqual(@as(f32, 0.3), pass.uniforms.b);
    // Defaulted fields stay zero (flat extern struct, unused = 0).
    try testing.expectEqual(@as(f32, 0), pass.uniforms.scalar2);
    try testing.expectEqual(@as(u32, 0), pass.uniforms.aux_texture);
}

test "a slice of PostPass carries across the engine setPostFx signature type" {
    // The runtime mutator takes `[]const engine.PostPass`; assert a stack
    // literal is assignable to that slice type (compile-time proof the seam
    // types line up, without constructing a heavy Game).
    const stack: []const engine.PostPass = &.{
        .{ .kind = .bloom, .uniforms = .{ .scalar0 = 1.0 } },
        .{ .kind = .crt },
    };
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(engine.PostPassKind.bloom, stack[0].kind);
    try testing.expectEqual(engine.PostPassKind.crt, stack[1].kind);
}

// ── Forwarding seam: Game.setPostFx/pushPostPass/clearPostFx → renderer.inner ──
//
// The mixin (`src/game/post_fx_mixin.zig`) forwards to
// `self.renderer.inner.<method>`, gated on
// `@hasDecl(Renderer, "GfxEngineType") and @hasDecl(Renderer.GfxEngineType, "setPostFx")`.
// The recording renderer below mirrors the real gfx `GfxRenderer` shape (a
// `pub const GfxEngineType` plus an `inner: GfxEngineType` field) and RECORDS
// every post-fx call on its `inner`, so we can assert the forward genuinely
// reaches `renderer.inner` — not merely that it compiles.

/// Stands in for gfx's retained engine: exposes the three post-fx runtime
/// methods the mixin calls and records what it was handed.
const RecordingGfxEngine = struct {
    set_calls: usize = 0,
    last_set_len: usize = 0,
    last_set_kinds: [8]PostPassKind = undefined,
    push_calls: usize = 0,
    last_pushed: ?PostPass = null,
    clear_calls: usize = 0,

    pub fn setPostFx(self: *@This(), passes: []const PostPass) void {
        self.set_calls += 1;
        self.last_set_len = passes.len;
        for (passes, 0..) |p, i| {
            if (i < self.last_set_kinds.len) self.last_set_kinds[i] = p.kind;
        }
    }
    pub fn pushPostPass(self: *@This(), pass: PostPass) void {
        self.push_calls += 1;
        self.last_pushed = pass;
    }
    pub fn clearPostFx(self: *@This()) void {
        self.clear_calls += 1;
    }
};

/// A renderer that satisfies the engine's RenderInterface (mirrors
/// `StubRender`, like render_mesh_test's RecordingRender) AND presents the
/// gfx-shaped `GfxEngineType`/`inner` structure the post-fx mixin keys off.
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

        /// The two decls the mixin's `rendererHasPostFx` guard requires.
        pub const GfxEngineType = RecordingGfxEngine;
        inner: RecordingGfxEngine = .{},

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}

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

test "Game.setPostFx/pushPostPass/clearPostFx forward to renderer.inner" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    // setPostFx forwards the whole stack.
    game.setPostFx(&.{
        .{ .kind = .bloom, .uniforms = .{ .scalar0 = 1.0 } },
        .{ .kind = .crt },
    });
    try testing.expectEqual(@as(usize, 1), game.renderer.inner.set_calls);
    try testing.expectEqual(@as(usize, 2), game.renderer.inner.last_set_len);
    try testing.expectEqual(PostPassKind.bloom, game.renderer.inner.last_set_kinds[0]);
    try testing.expectEqual(PostPassKind.crt, game.renderer.inner.last_set_kinds[1]);

    // pushPostPass forwards a single pass with its uniforms.
    game.pushPostPass(.{ .kind = .vignette, .uniforms = .{ .scalar0 = 0.7 } });
    try testing.expectEqual(@as(usize, 1), game.renderer.inner.push_calls);
    try testing.expect(game.renderer.inner.last_pushed != null);
    try testing.expectEqual(PostPassKind.vignette, game.renderer.inner.last_pushed.?.kind);
    try testing.expectEqual(@as(f32, 0.7), game.renderer.inner.last_pushed.?.uniforms.scalar0);

    // clearPostFx forwards the reset.
    game.clearPostFx();
    try testing.expectEqual(@as(usize, 1), game.renderer.inner.clear_calls);
    // The earlier forwards were not disturbed by the clear.
    try testing.expectEqual(@as(usize, 1), game.renderer.inner.set_calls);
    try testing.expectEqual(@as(usize, 1), game.renderer.inner.push_calls);
}

test "post-fx methods are safe no-ops on a renderer without GfxEngineType (back-compat)" {
    // The default engine.Game uses StubRender, which has no `GfxEngineType` —
    // the mixin's comptime guard fails, so all three calls compile to nothing
    // and must not crash or touch anything (older gfx / StubRender / mock path).
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    game.setPostFx(&.{
        .{ .kind = .bloom },
        .{ .kind = .crt },
    });
    game.pushPostPass(.{ .kind = .vignette, .uniforms = .{ .scalar0 = 0.5 } });
    game.clearPostFx();
    // Reaching here without a crash is the assertion: guarded no-op.
}
