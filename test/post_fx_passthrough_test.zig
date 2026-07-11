//! Post-fx stack passthrough + type re-export (labelle-gfx#305 Phase 2 Slice C).
//!
//! Two things under test:
//!   1. The engine surfaces the post-fx VALUE TYPES (`engine.PostPass` /
//!      `PostPassKind` / `PostPassUniforms`) and they are the SAME core types
//!      gfx re-exports — proving the diamond stays unified (the engine takes no
//!      gfx module dependency; the types come from labelle-core).
//!   2. A `PostPass` literal built through the engine surface round-trips its
//!      uniform fields, so a game / assembler-generated main.zig can seed the
//!      `.post_fx` stack via `engine.PostPass{ ... }`.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");

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
