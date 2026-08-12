//! Tests for `engine.sourceRectFor` — the mapping from a resolved
//! atlas lookup onto the renderer's `source_rect`.
//!
//! This is the seam the trim-offset bug lived in: `atlas.zig` parsed each
//! frame's `spriteSourceSize` into `SpriteData.offset_x/offset_y`, and for
//! a long time nothing read those fields back, so a trimmed frame was
//! drawn centred on its own silhouette instead of on the canvas the artist
//! authored. Nothing failed and nothing logged — the only test that can
//! catch that class of bug is one asserting the parsed value ARRIVES.
//!
//! The renderer's real `SourceRect` lives in labelle-gfx, so these tests
//! use local stand-ins with the same field names: `TrimAware` mirrors a
//! current gfx, `Legacy` an older one without the trim fields (the mapping
//! is `@hasField`-gated so the engine still compiles against it).

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const SpriteData = engine.SpriteData;
const FindSpriteResult = engine.FindSpriteResult;

/// A gfx `SourceRect` that carries the trim geometry.
const TrimAware = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    display_width: f32 = 0,
    display_height: f32 = 0,
    trim_offset_x: f32 = 0,
    trim_offset_y: f32 = 0,
    canvas_width: f32 = 0,
    canvas_height: f32 = 0,
};

/// A gfx `SourceRect` from before the trim fields existed.
const Legacy = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    display_width: f32 = 0,
    display_height: f32 = 0,
};

/// A worker frame as TexturePacker would report it: authored on a 60x69
/// canvas, cropped to the 40x60 window sitting 12px in and 9px down.
fn trimmedFrame() FindSpriteResult {
    return .{
        .sprite = .{
            .x = 100,
            .y = 200,
            .width = 40,
            .height = 60,
            .source_width = 60,
            .source_height = 69,
            .offset_x = 12,
            .offset_y = 9,
            .trimmed = true,
        },
        .texture_id = 7,
    };
}

test "a trimmed frame's offsets and canvas reach the source rect" {
    // The regression guard for the original defect. If this fails, trimmed
    // atlases are being drawn centred on their silhouettes again.
    const rect = engine.sourceRectFor(TrimAware, trimmedFrame());

    try testing.expectEqual(@as(f32, 12), rect.trim_offset_x);
    try testing.expectEqual(@as(f32, 9), rect.trim_offset_y);
    try testing.expectEqual(@as(f32, 60), rect.canvas_width);
    try testing.expectEqual(@as(f32, 69), rect.canvas_height);
    // The sub-rect itself is still the packed 40x60 at its atlas position.
    try testing.expectEqual(@as(f32, 100), rect.x);
    try testing.expectEqual(@as(f32, 40), rect.width);
    try testing.expectEqual(@as(f32, 40), rect.display_width);
    try testing.expectEqual(@as(f32, 60), rect.display_height);
}

test "an untrimmed frame reports a canvas equal to its frame, offsets zero" {
    var result = trimmedFrame();
    result.sprite = .{ .x = 0, .y = 0, .width = 40, .height = 60 };
    const rect = engine.sourceRectFor(TrimAware, result);

    try testing.expectEqual(@as(f32, 0), rect.trim_offset_x);
    try testing.expectEqual(@as(f32, 0), rect.trim_offset_y);
    // `getSourceWidth/Height` fall back to the display size when the atlas
    // omitted `sourceSize`, so the canvas IS the frame — which makes the
    // renderer's pivot math collapse to the pre-trim behaviour.
    try testing.expectEqual(@as(f32, 40), rect.canvas_width);
    try testing.expectEqual(@as(f32, 60), rect.canvas_height);
}

test "a rotated frame gets no trim correction" {
    // `offset_*` is expressed in the UNROTATED canvas, so applying it to a
    // 90°-rotated frame would displace it along the wrong axis. Better to
    // leave the pre-fix geometry than to apply a wrong correction.
    var result = trimmedFrame();
    result.sprite.rotated = true;
    const rect = engine.sourceRectFor(TrimAware, result);

    try testing.expectEqual(@as(f32, 0), rect.trim_offset_x);
    try testing.expectEqual(@as(f32, 0), rect.trim_offset_y);
    try testing.expectEqual(@as(f32, 0), rect.canvas_width);
    try testing.expectEqual(@as(f32, 0), rect.canvas_height);
    // Rotation still swaps the sub-rect extents.
    try testing.expectEqual(@as(f32, 60), rect.width);
    try testing.expectEqual(@as(f32, 40), rect.height);
    // ...and the display dims, which are the post-rotation on-screen size.
    try testing.expectEqual(@as(f32, 60), rect.display_width);
    try testing.expectEqual(@as(f32, 40), rect.display_height);
}

test "a legacy source rect without trim fields still maps" {
    // The engine must keep compiling (and behaving as before) against a
    // gfx whose SourceRect predates the trim fields.
    const rect = engine.sourceRectFor(Legacy, trimmedFrame());
    try testing.expectEqual(@as(f32, 100), rect.x);
    try testing.expectEqual(@as(f32, 40), rect.width);
    try testing.expectEqual(@as(f32, 40), rect.display_width);
}

test "the rect type resolves whether source_rect is optional or not" {
    // A renderer owns its own `Sprite`, and the engine only requires the
    // field to exist — some declare `source_rect: ?SourceRect`, others the
    // rect directly (`test/asset_streaming_shim_test.zig` does). Both must
    // instantiate; unwrapping the optional unconditionally refused to
    // compile against the second kind.
    const Optional = struct { source_rect: ?TrimAware = null };
    const Direct = struct { source_rect: TrimAware = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    try testing.expectEqual(TrimAware, engine.SourceRectOf(Optional));
    try testing.expectEqual(TrimAware, engine.SourceRectOf(Direct));
}

test "texture scale applies to the atlas footprint but not the trim geometry" {
    // A downscaled PNG shrinks the texture sub-rect (UV sampling follows
    // the smaller texture) while design-space values — display size AND
    // the trim geometry — must stay put, or the sprite changes size and
    // position on screen just because the texture was resized.
    var result = trimmedFrame();
    result.texture_scale_x = 0.5;
    result.texture_scale_y = 0.5;
    const rect = engine.sourceRectFor(TrimAware, result);

    try testing.expectEqual(@as(f32, 50), rect.x);
    try testing.expectEqual(@as(f32, 100), rect.y);
    try testing.expectEqual(@as(f32, 20), rect.width);
    try testing.expectEqual(@as(f32, 30), rect.height);
    // Un-scaled: design space.
    try testing.expectEqual(@as(f32, 40), rect.display_width);
    try testing.expectEqual(@as(f32, 60), rect.display_height);
    try testing.expectEqual(@as(f32, 12), rect.trim_offset_x);
    try testing.expectEqual(@as(f32, 60), rect.canvas_width);
}
