const std = @import("std");

const engine = @import("engine");
const easing = engine.easing;
const Curve = easing.Curve;
const Placement = easing.Placement;

const all_curves = [_]Curve{ .linear, .sine, .quad, .cubic, .quart, .quint, .expo, .circ, .back, .elastic, .bounce, .spring };
const all_placements = [_]Placement{ .in, .out, .in_out, .out_in };

// Curves that rise monotonically in their `.in` form (no overshoot).
const monotonic_in = [_]Curve{ .linear, .sine, .quad, .cubic, .quart, .quint, .expo, .circ };

test "endpoints are exact for every (curve, placement)" {
    for (all_curves) |c| {
        for (all_placements) |p| {
            // Exact 0/1 — callers rely on it; 0 tolerance is the point.
            try std.testing.expectEqual(@as(f32, 0.0), easing.ease(c, p, 0.0));
            try std.testing.expectEqual(@as(f32, 1.0), easing.ease(c, p, 1.0));
        }
    }
}

test "monotonic curves are non-decreasing in .in placement" {
    for (monotonic_in) |c| {
        var prev: f32 = -1.0;
        var i: usize = 0;
        while (i <= 100) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 100.0;
            const v = easing.ease(c, .in, t);
            try std.testing.expect(v >= prev - 1e-6);
            prev = v;
        }
    }
}

test "quad/.out is bit-identical to the game's easeOutQuad" {
    // ship_animation.zig: easeOutQuad(t) = 1 - (1-t)^2.
    const samples = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    for (samples) |t| {
        const u = 1.0 - t;
        const expected = 1.0 - u * u;
        try std.testing.expectEqual(expected, easing.ease(.quad, .out, t));
    }
}

test "out placement mirrors in: ease(c,.out,t) == 1 - ease(c,.in,1-t)" {
    for (all_curves) |c| {
        // Sample the open interval so neither t nor 1-t hits the forced endpoints.
        var i: usize = 1;
        while (i < 100) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 100.0;
            const lhs = easing.ease(c, .out, t);
            const rhs = 1.0 - easing.ease(c, .in, 1.0 - t);
            try std.testing.expectApproxEqAbs(lhs, rhs, 1e-5);
        }
    }
}

test "in_out midpoint is 0.5 for every curve" {
    // curveIn(c, 1.0) == 1 for all curves, so in_out(0.5) = 1 - 1/2 = 0.5.
    for (all_curves) |c| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), easing.ease(c, .in_out, 0.5), 1e-5);
    }
}

test "input t is clamped, output is not (overshoot preserved)" {
    // Clamp of the INPUT.
    try std.testing.expectEqual(@as(f32, 0.0), easing.ease(.quad, .in, -1.0));
    try std.testing.expectEqual(@as(f32, 1.0), easing.ease(.quad, .in, 2.0));
    // back overshoots below 0 in .in near the start — output must NOT clamp.
    try std.testing.expect(easing.ease(.back, .in, 0.2) < 0.0);
    // elastic overshoots above 1 in .out near the end.
    var over = false;
    var i: usize = 1;
    while (i < 100) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 100.0;
        if (easing.ease(.elastic, .out, t) > 1.0) over = true;
    }
    try std.testing.expect(over);
}

test "interpolate maps through start + delta * ease" {
    // linear halfway: 10 + 20 * 0.5 == 20.
    try std.testing.expectEqual(@as(f32, 20.0), easing.interpolate(10, 20, 1, 2, .linear, .in));
    // duration <= 0 → instantly finished (start + delta), no div-by-zero.
    try std.testing.expectEqual(@as(f32, 30.0), easing.interpolate(10, 20, 5, 0, .quad, .out));
    try std.testing.expectEqual(@as(f32, 30.0), easing.interpolate(10, 20, 5, -1, .quad, .out));
    // endpoints.
    try std.testing.expectEqual(@as(f32, 10.0), easing.interpolate(10, 20, 0, 2, .cubic, .in_out));
    try std.testing.expectEqual(@as(f32, 30.0), easing.interpolate(10, 20, 2, 2, .cubic, .in_out));
}

test "expApproach reproduces 1 - exp(-rate*dt)" {
    const dts = [_]f32{ 0.0, 0.008, 0.016, 0.033, 0.1 };
    for (dts) |dt| {
        try std.testing.expectEqual(1.0 - @exp(-8.0 * dt), easing.expApproach(8.0, dt));
    }
    // dt == 0 → no movement.
    try std.testing.expectEqual(@as(f32, 0.0), easing.expApproach(8.0, 0.0));
}
