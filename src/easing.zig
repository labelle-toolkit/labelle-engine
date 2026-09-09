//! easing — pure interpolation catalog. No allocations, no dependencies
//! on ECS / renderer / game state. Every function is a pure `f32→f32`
//! (or small-scalar) map, so scripts, the future tween system, and
//! camera smoothing can all call it directly.
//!
//! Design (labelle-engine#668, after Godot 4's Tween): two orthogonal
//! axes — a `Curve` (the shape) crossed with a `Placement` (where the
//! shape sits in the [0,1] interval) — instead of a flat list of named
//! eases. 12 curves × 4 placements ≈ 45 useful combinations from 16
//! enum values, and the two enum fields serialize trivially into
//! ZON/JSONC for future data-driven tweens.
//!
//! Only the `in` form of each curve is written out (`curveIn`); the
//! other three placements are derived generically, so a new curve is
//! one arm of one switch. Endpoints are forced exact in `ease` (t=0→0,
//! t=1→1) for every combination; the `back`/`elastic` mid-range
//! overshoot is preserved (output is never clamped, only input t).

const std = @import("std");

pub const Curve = enum(u8) {
    linear, // t
    sine, // 1 - cos(t·π/2)
    quad, // t²
    cubic, // t³
    quart, // t⁴
    quint, // t⁵
    expo, // 2^(10(t-1)), with expo(0)==0 special case
    circ, // 1 - √(1 - t²)
    back, // overshoot: c3·t³ - c1·t², c1=1.70158, c3=c1+1
    elastic, // damped sine overshoot
    bounce, // piecewise parabolic bounce
    spring, // damped spring settle (Godot TRANS_SPRING)
};

pub const Placement = enum(u8) {
    in, // curve applied at the start
    out, // curve mirrored to the end: 1 - f(1 - t)
    in_out, // f scaled into [0,0.5), mirrored into [0.5,1]
    out_in, // mirror of in_out
};

// `back` overshoot constant (Penner / easings.net canonical value).
const back_c1: f32 = 1.70158;
const back_c3: f32 = back_c1 + 1.0;

// `elastic` period (Penner default). s = period/4 = 0.075 is the phase
// shift that lands the in-form on 1.0 at t=1.
const elastic_period: f32 = 0.3;

/// Map normalized `t` through `(curve, placement)`. Pure function.
/// `t` is clamped to [0,1]; the OUTPUT is not clamped, so `back` and
/// `elastic` keep their mid-range overshoot. Endpoints are exact for
/// every combination. `placement` is a no-op for `.linear`.
pub fn ease(curve: Curve, placement: Placement, t: f32) f32 {
    const ct = std.math.clamp(t, 0.0, 1.0);
    // Force exact endpoints — the raw formulas drift by an ULP or two
    // in f32 (e.g. cos(π/2) ≠ 0 exactly), and callers rely on 0/1.
    if (ct == 0.0) return 0.0;
    if (ct == 1.0) return 1.0;
    return switch (placement) {
        .in => curveIn(curve, ct),
        .out => 1.0 - curveIn(curve, 1.0 - ct),
        .in_out => if (ct < 0.5)
            curveIn(curve, 2.0 * ct) / 2.0
        else
            1.0 - curveIn(curve, 2.0 - 2.0 * ct) / 2.0,
        .out_in => if (ct < 0.5)
            (1.0 - curveIn(curve, 1.0 - 2.0 * ct)) / 2.0
        else
            0.5 + curveIn(curve, 2.0 * ct - 1.0) / 2.0,
    };
}

/// Godot `Tween.interpolate_value` equivalent:
/// `start + delta · ease(curve, placement, elapsed / duration)`.
/// `duration <= 0` returns `start + delta` (treated as instantly done),
/// so there is no division by zero.
pub fn interpolate(
    start: f32,
    delta: f32,
    elapsed: f32,
    duration: f32,
    curve: Curve,
    placement: Placement,
) f32 {
    if (duration <= 0.0) return start + delta;
    return start + delta * ease(curve, placement, elapsed / duration);
}

/// Frame-rate-independent exponential approach factor: `1 - exp(-rate·dt)`.
/// For "chase a moving target" smoothing (`x += (target - x) * factor`) —
/// NOT a normalized-t ease. Extracted from the hand-rolled camera pattern
/// (`camera_control.zig`).
pub fn expApproach(rate: f32, dt: f32) f32 {
    return 1.0 - @exp(-rate * dt);
}

/// The `in` form of each curve on t ∈ [0,1]. All other placements in
/// `ease` derive from this. Endpoints here are near-exact but `ease`
/// forces them; the mid-range shape is what matters.
fn curveIn(curve: Curve, t: f32) f32 {
    return switch (curve) {
        .linear => t,
        .sine => 1.0 - @cos(t * std.math.pi / 2.0),
        .quad => t * t,
        .cubic => t * t * t,
        .quart => t * t * t * t,
        .quint => t * t * t * t * t,
        .expo => if (t == 0.0) 0.0 else std.math.pow(f32, 2.0, 10.0 * (t - 1.0)),
        .circ => 1.0 - @sqrt(1.0 - t * t),
        .back => back_c3 * t * t * t - back_c1 * t * t,
        .elastic => elasticIn(t),
        .bounce => 1.0 - bounceOut(1.0 - t), // canonical bounce is an OUT shape
        .spring => 1.0 - springOut(1.0 - t), // Godot: spring in = c - out(d - t)
    };
}

fn elasticIn(t: f32) f32 {
    if (t == 0.0) return 0.0;
    if (t == 1.0) return 1.0;
    const s = elastic_period / 4.0; // 0.075
    return -std.math.pow(f32, 2.0, 10.0 * (t - 1.0)) *
        @sin((t - 1.0 - s) * 2.0 * std.math.pi / elastic_period);
}

fn bounceOut(t: f32) f32 {
    const n1: f32 = 7.5625;
    const d1: f32 = 2.75;
    if (t < 1.0 / d1) {
        return n1 * t * t;
    } else if (t < 2.0 / d1) {
        const u = t - 1.5 / d1;
        return n1 * u * u + 0.75;
    } else if (t < 2.5 / d1) {
        const u = t - 2.25 / d1;
        return n1 * u * u + 0.9375;
    } else {
        const u = t - 2.625 / d1;
        return n1 * u * u + 0.984375;
    }
}

// Godot's TRANS_SPRING out-equation (scene/animation/easing_equations.h),
// normalized to b=0, c=1, d=1. Constants (0.2, 2.5, 2.2, 1.2) are Godot's;
// determinism matters more than matching bit-for-bit, so they're pinned
// here. Exact at both ends: springOut(0)=0, springOut(1)=1.
fn springOut(t: f32) f32 {
    const s = 1.0 - t;
    return (@sin(t * std.math.pi * (0.2 + 2.5 * t * t * t)) *
        std.math.pow(f32, s, 2.2) + t) * (1.0 + 1.2 * s);
}
