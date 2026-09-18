//! `PixelWater` — the engine-side authoring component for the built-in
//! `MaterialEffect.pixel_water` reservoir effect (COND-07, labelle-bgfx#100,
//! RFC-PIXEL-WATER phase 5).
//!
//! This module is the AUTHORING half. It owns:
//!
//!   * `PixelWater` — the flat ECS component a scene / prefab authors, shaped
//!     exactly like the RFC's "Proposed authoring model" block.
//!   * `PixelWaterSettings` — the public, backend-independent value
//!     `game.setWaterSettings` takes: the NON-structural subset (waves,
//!     distortion, reflection opacity, colour ramps, ripple appearance).
//!   * Validation with a named field + reason, so a bad scene value reports
//!     `PixelWater on entity 7: field 'ripple_radius_pixels' must be > 0`
//!     instead of a GPU-side mystery.
//!   * The ONE sRGB→linear conversion (`srgbToLinear`).
//!
//! It deliberately owns NO runtime state. Ripple expiry, the eight-impact cap
//! and the deterministic oldest-replacement live in labelle-gfx's gfx-owned
//! water-instance store (`pixel_water.zig` there); the engine delegates.
//!
//! ── Why colours are authored as HEX STRINGS, here and at runtime ──────────
//!
//! `PixelWaterRgba` at the backend seam is LINEAR 0..1. The authored value is
//! sRGB hex. Converting in two places invites the double-gamma bug the RFC
//! warns about, so the rule here is: the component and `PixelWaterSettings`
//! both carry the AUTHORED sRGB hex string, and the single conversion happens
//! once, at the `toWaterConfig` seam where the gfx `WaterConfig` is built.
//! There is no other place in the engine that touches these channels, so no
//! path can convert twice — and a game's runtime `setWaterSettings` uses the
//! very same representation the scene authored, which is what makes the
//! "JSON / ZON / runtime produce identical settings" test meaningful rather
//! than a coincidence of three separate parsers agreeing.
//!
//! String lifetime: the hex and asset-name slices are borrowed, exactly like
//! `Sprite.sprite_name` / `Image.name`. Scene-authored values live in the
//! world's nested-entity arena (or the deserializer's intern pool); a runtime
//! caller passes a string literal or something that outlives the component.

const std = @import("std");
const save_policy = @import("labelle-core").save_policy;

// ── Colour ──────────────────────────────────────────────────────────────

/// An sRGB, byte-per-channel authored colour — the parsed form of a
/// `"#RRGGBB"` / `"#RRGGBBAA"` authoring string. Public so a game can
/// pre-validate a colour, or build one without going through hex.
pub const PixelWaterColor = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

pub const HexColorError = error{InvalidHexColor};

/// Parse `"#RRGGBB"` or `"#RRGGBBAA"` (the leading `#` optional) into sRGB
/// bytes. Strict: any other length, or a non-hex digit, is an error the
/// caller turns into a field-named diagnostic. No 3-digit shorthand — the
/// RFC's authored palette is 6-digit and a silent shorthand expansion is one
/// more way for two authoring paths to disagree.
pub fn parseHexColor(text: []const u8) HexColorError!PixelWaterColor {
    var s = text;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6 and s.len != 8) return error.InvalidHexColor;

    var out: PixelWaterColor = .{};
    const channels = [_]*u8{ &out.r, &out.g, &out.b, &out.a };
    var i: usize = 0;
    while (i * 2 < s.len) : (i += 1) {
        const hi = hexDigit(s[i * 2]) orelse return error.InvalidHexColor;
        const lo = hexDigit(s[i * 2 + 1]) orelse return error.InvalidHexColor;
        channels[i].* = (hi << 4) | lo;
    }
    return out;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The IEC 61966-2-1 sRGB electro-optical transfer function, applied to one
/// 0..255 authored channel to produce the linear 0..1 value the shader wants.
///
/// THE single gamma conversion in the engine's water path. Alpha is NOT put
/// through it (alpha is linear coverage, never gamma-encoded) — see
/// `toLinearRgba`.
pub fn srgbToLinear(channel: u8) f32 {
    const c = @as(f32, @floatFromInt(channel)) / 255.0;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// Convert an authored sRGB colour into `Rgba`'s linear 0..1 channels.
/// `Rgba` is passed in as a type parameter rather than imported from
/// labelle-core so this module — like the rest of the engine — keeps no
/// compile-time dependency on the renderer's contract surface: the concrete
/// type is read off the renderer's own `WaterConfig` at the call site.
pub fn toLinearRgba(comptime Rgba: type, c: PixelWaterColor) Rgba {
    return .{
        .r = srgbToLinear(c.r),
        .g = srgbToLinear(c.g),
        .b = srgbToLinear(c.b),
        // Alpha is coverage, not light: linear already. Running it through
        // the EOTF is the classic double-gamma-on-alpha bug.
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

// ── Settings (the non-structural, runtime-settable subset) ───────────────

/// The value `game.setWaterSettings` takes: everything the RFC lists as
/// runtime-settable — waves, distortion, reflection opacity, colour ramps and
/// ripple appearance.
///
/// Explicitly NOT here: `mask` / `reflection` / `logical_size` / `grid_pixels`
/// (structural — they change through explicit reconfiguration) and
/// `water_level` (its own setter, with its own ripple-clearing semantics).
pub const PixelWaterSettings = struct {
    deep_color: []const u8 = "#0E1C24",
    surface_color: []const u8 = "#2D4E5B",
    highlight_color: []const u8 = "#9FC0BC",

    wave_amplitude_pixels: f32 = 0,
    wave_period_seconds: f32 = 3,
    /// Toggles waves without destroying the authored amplitude (which
    /// setting the amplitude to zero would).
    waves_enabled: bool = true,

    reflection_opacity: f32 = 0,
    distortion_pixels: f32 = 0,

    ripple_duration_seconds: f32 = 0.8,
    ripple_radius_pixels: f32 = 6,
    /// AUTHORED peak displacement, in native art pixels, of a
    /// full-strength impact. Nonnegative. The runtime `addWaterRipple`
    /// strength is a DIMENSIONLESS [0,1] scale on this — see
    /// `validateRippleStrength`.
    ripple_strength_pixels: f32 = 1,
};

/// The authored component. Flat, mirroring the RFC's JSON block 1:1 so a
/// scene key and a field name are the same word.
pub const PixelWater = struct {
    /// Transient: the reservoir's authored configuration is re-derived from
    /// the scene/prefab on load, and the live instance (simulation time,
    /// active impacts) is presentation state that resets cleanly. Same policy
    /// as `Emitter` / `SpriteAnimation`.
    pub const save = save_policy.Saveable(.transient, @This(), .{});

    /// Reservoir silhouette mask — an `AssetCatalog` standalone-image key.
    /// REQUIRED: without it the effect is unrenderable.
    mask: []const u8 = "",
    /// Supplied, pre-authored reflection texture. Optional.
    reflection: []const u8 = "",
    /// Reservoir rectangle in native art pixels, `[width, height]`.
    logical_size: [2]u32 = .{ 0, 0 },
    /// Native art pixels per effect cell.
    grid_pixels: u32 = 1,
    /// Initial fill fraction from the bottom, [0, 1].
    water_level: f32 = 0,

    deep_color: []const u8 = "#0E1C24",
    surface_color: []const u8 = "#2D4E5B",
    highlight_color: []const u8 = "#9FC0BC",

    wave_amplitude_pixels: f32 = 0,
    wave_period_seconds: f32 = 3,
    waves_enabled: bool = true,

    reflection_opacity: f32 = 0,
    distortion_pixels: f32 = 0,

    ripple_duration_seconds: f32 = 0.8,
    ripple_radius_pixels: f32 = 6,
    ripple_strength_pixels: f32 = 1,

    /// The non-structural subset, as a `PixelWaterSettings`.
    pub fn settings(self: PixelWater) PixelWaterSettings {
        return .{
            .deep_color = self.deep_color,
            .surface_color = self.surface_color,
            .highlight_color = self.highlight_color,
            .wave_amplitude_pixels = self.wave_amplitude_pixels,
            .wave_period_seconds = self.wave_period_seconds,
            .waves_enabled = self.waves_enabled,
            .reflection_opacity = self.reflection_opacity,
            .distortion_pixels = self.distortion_pixels,
            .ripple_duration_seconds = self.ripple_duration_seconds,
            .ripple_radius_pixels = self.ripple_radius_pixels,
            .ripple_strength_pixels = self.ripple_strength_pixels,
        };
    }

    /// Overlay `s` onto the component's non-structural fields. Pure — the
    /// caller decides when (and whether) to commit the result, which is what
    /// makes stage-before-commit expressible: `setWaterSettings` builds the
    /// candidate with this, validates and pushes it to gfx, and only then
    /// writes the candidate back over the live component.
    pub fn withSettings(self: PixelWater, s: PixelWaterSettings) PixelWater {
        var out = self;
        out.deep_color = s.deep_color;
        out.surface_color = s.surface_color;
        out.highlight_color = s.highlight_color;
        out.wave_amplitude_pixels = s.wave_amplitude_pixels;
        out.wave_period_seconds = s.wave_period_seconds;
        out.waves_enabled = s.waves_enabled;
        out.reflection_opacity = s.reflection_opacity;
        out.distortion_pixels = s.distortion_pixels;
        out.ripple_duration_seconds = s.ripple_duration_seconds;
        out.ripple_radius_pixels = s.ripple_radius_pixels;
        out.ripple_strength_pixels = s.ripple_strength_pixels;
        return out;
    }
};

// ── Validation ──────────────────────────────────────────────────────────

/// Which authored field a diagnostic is about. Names match the scene keys
/// exactly, so `@tagName` is the string an author can search their `.jsonc`
/// for.
pub const PixelWaterField = enum {
    mask,
    reflection,
    logical_size,
    grid_pixels,
    water_level,
    deep_color,
    surface_color,
    highlight_color,
    wave_amplitude_pixels,
    wave_period_seconds,
    reflection_opacity,
    distortion_pixels,
    ripple_duration_seconds,
    ripple_radius_pixels,
    ripple_strength_pixels,
    /// The runtime `addWaterRipple` strength argument. Not an authored
    /// field — it shares the diagnostic channel because it is the OTHER
    /// half of the bounded-strength rule.
    strength,
    /// The runtime `addWaterRipple` local-X argument.
    ripple_x,
};

/// Why a value was rejected. Rendered into the diagnostic verbatim.
pub const PixelWaterReason = enum {
    missing,
    non_finite,
    negative,
    not_positive,
    out_of_unit_range,
    invalid_hex,

    pub fn text(self: PixelWaterReason) []const u8 {
        return switch (self) {
            .missing => "is required and must not be empty",
            .non_finite => "must be finite (NaN / Infinity rejected)",
            .negative => "must be >= 0",
            .not_positive => "must be > 0",
            .out_of_unit_range => "must be within [0, 1]",
            .invalid_hex => "must be an sRGB hex colour (\"#RRGGBB\" or \"#RRGGBBAA\")",
        };
    }
};

pub const PixelWaterIssue = struct {
    field: PixelWaterField,
    reason: PixelWaterReason,
};

/// Error set the game-facing helpers return. Deliberately coarse: the
/// ACTIONABLE detail is the logged `PixelWaterIssue` (field + reason), which
/// an error tag could never carry.
pub const PixelWaterError = error{
    /// An authored or runtime settings value failed `validateSettings` /
    /// `validateComponent`. Nothing was committed on either side.
    InvalidPixelWater,
    /// The entity carries no `PixelWater` component.
    NoPixelWater,
    /// The renderer rejected the staged configuration (stale instance,
    /// or its own validation disagreed). Nothing was committed on either
    /// side.
    PixelWaterRejected,
};

fn finite(v: f32) bool {
    return std.math.isFinite(v);
}

fn checkColor(field: PixelWaterField, hex: []const u8) ?PixelWaterIssue {
    _ = parseHexColor(hex) catch return .{ .field = field, .reason = .invalid_hex };
    return null;
}

/// Validate the runtime-settable subset. Returns the FIRST offending field,
/// or `null` when the value is acceptable.
///
/// `ripple_strength_pixels` is checked here as a NONNEGATIVE PIXEL AMPLITUDE.
/// Its runtime counterpart — the dimensionless [0,1] scale passed to
/// `addWaterRipple` — is checked by `validateRippleStrength`. Both boundaries
/// are enforced: a bound on only one of them leaves the other as the way
/// around it (RFC §"Runtime state and API").
pub fn validateSettings(s: PixelWaterSettings) ?PixelWaterIssue {
    if (checkColor(.deep_color, s.deep_color)) |i| return i;
    if (checkColor(.surface_color, s.surface_color)) |i| return i;
    if (checkColor(.highlight_color, s.highlight_color)) |i| return i;

    if (!finite(s.wave_amplitude_pixels)) return .{ .field = .wave_amplitude_pixels, .reason = .non_finite };
    if (s.wave_amplitude_pixels < 0) return .{ .field = .wave_amplitude_pixels, .reason = .negative };

    if (!finite(s.wave_period_seconds)) return .{ .field = .wave_period_seconds, .reason = .non_finite };
    if (s.wave_period_seconds <= 0) return .{ .field = .wave_period_seconds, .reason = .not_positive };

    if (!finite(s.reflection_opacity)) return .{ .field = .reflection_opacity, .reason = .non_finite };
    if (s.reflection_opacity < 0 or s.reflection_opacity > 1) {
        return .{ .field = .reflection_opacity, .reason = .out_of_unit_range };
    }

    if (!finite(s.distortion_pixels)) return .{ .field = .distortion_pixels, .reason = .non_finite };
    if (s.distortion_pixels < 0) return .{ .field = .distortion_pixels, .reason = .negative };

    if (!finite(s.ripple_duration_seconds)) return .{ .field = .ripple_duration_seconds, .reason = .non_finite };
    if (s.ripple_duration_seconds <= 0) return .{ .field = .ripple_duration_seconds, .reason = .not_positive };

    if (!finite(s.ripple_radius_pixels)) return .{ .field = .ripple_radius_pixels, .reason = .non_finite };
    if (s.ripple_radius_pixels <= 0) return .{ .field = .ripple_radius_pixels, .reason = .not_positive };

    // BOUNDARY 1 of the bounded-strength rule: the authored pixel amplitude.
    if (!finite(s.ripple_strength_pixels)) return .{ .field = .ripple_strength_pixels, .reason = .non_finite };
    if (s.ripple_strength_pixels < 0) return .{ .field = .ripple_strength_pixels, .reason = .negative };

    return null;
}

/// Validate the whole authored component: the structural fields plus
/// `validateSettings`.
pub fn validateComponent(c: PixelWater) ?PixelWaterIssue {
    if (c.mask.len == 0) return .{ .field = .mask, .reason = .missing };
    if (c.logical_size[0] == 0 or c.logical_size[1] == 0) {
        return .{ .field = .logical_size, .reason = .not_positive };
    }
    if (c.grid_pixels == 0) return .{ .field = .grid_pixels, .reason = .not_positive };

    if (!finite(c.water_level)) return .{ .field = .water_level, .reason = .non_finite };
    if (c.water_level < 0 or c.water_level > 1) {
        return .{ .field = .water_level, .reason = .out_of_unit_range };
    }

    return validateSettings(c.settings());
}

/// BOUNDARY 2 of the bounded-strength rule.
///
/// The runtime `strength` handed to `addWaterRipple` is a DIMENSIONLESS
/// magnitude in [0, 1] that SCALES the authored `ripple_strength_pixels`. It
/// is not itself a pixel amplitude and it is not signed. Rejecting
/// non-finite, negative and > 1 here is what makes peak displacement at most
/// `ripple_strength_pixels` by construction, whatever a caller passes — the
/// authored setting stays the one place the effect's visual scale is retuned.
pub fn validateRippleStrength(strength: f32) ?PixelWaterIssue {
    if (!finite(strength)) return .{ .field = .strength, .reason = .non_finite };
    if (strength < 0) return .{ .field = .strength, .reason = .negative };
    if (strength > 1) return .{ .field = .strength, .reason = .out_of_unit_range };
    return null;
}

/// Runtime level updates clamp to [0, 1] but reject NaN/Infinity
/// (RFC §"Proposed authoring model").
pub fn validateLevel(level: f32) ?PixelWaterIssue {
    if (!finite(level)) return .{ .field = .water_level, .reason = .non_finite };
    return null;
}

// Coverage lives in `test/pixel_water_test.zig` — per the engine convention,
// `src/*.zig` test blocks aren't reached by build.zig's cross-module test
// import.
