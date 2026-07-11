/// Tests for the split-screen viewport layout math (#761 Phase 3).
///
/// Renderer-agnostic geometry: verifies the layouts tile the screen exactly
/// (no uncovered gap, no overlap on full-grid cases) and place each view
/// where the layout promises. The real per-layer `setViewport` + layer→camera
/// binding that consume these rects are gfx-repo work and aren't exercised
/// here.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Viewport = engine.CameraViewport;
const SplitLayout = engine.SplitLayout;
const splitScreen = engine.splitScreen;

const cvp = engine.camera_viewport_mod;

// ── Degenerate counts ──────────────────────────────────────────────────────

test "count 0 returns an empty slice" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(1920, 1080, 0, .horizontal, &buf);
    try testing.expectEqual(@as(usize, 0), vps.len);
}

test "count 1 is fullscreen for every layout" {
    var buf: [4]Viewport = undefined;
    inline for (.{ SplitLayout.horizontal, .vertical, .grid }) |layout| {
        const vps = splitScreen(1920, 1080, 1, layout, &buf);
        try testing.expectEqual(@as(usize, 1), vps.len);
        try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, vps[0]);
    }
}

test "count clamps to the output buffer length" {
    var buf: [2]Viewport = undefined;
    const vps = splitScreen(100, 100, 4, .vertical, &buf);
    try testing.expectEqual(@as(usize, 2), vps.len);
}

test "negative screen dimensions never produce negative viewport rects" {
    var buf: [4]Viewport = undefined;
    inline for (.{ SplitLayout.horizontal, .vertical, .grid }) |layout| {
        const vps = splitScreen(-1920, -1080, 4, layout, &buf);
        for (vps) |v| {
            try testing.expect(v.width >= 0);
            try testing.expect(v.height >= 0);
        }
    }
}

// ── Horizontal bands ───────────────────────────────────────────────────────

test "horizontal 2-way splits into stacked top/bottom halves" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(800, 600, 2, .horizontal, &buf);
    try testing.expectEqual(@as(usize, 2), vps.len);
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 800, .height = 300 }, vps[0]);
    try testing.expectEqual(Viewport{ .x = 0, .y = 300, .width = 800, .height = 300 }, vps[1]);
}

test "horizontal folds the division remainder into the last band (exact tiling)" {
    // 1080 / 4 = 270 exactly, but use an odd height to force a remainder.
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(500, 1001, 4, .horizontal, &buf);
    try expectTilesExactly(vps, 500, 1001);
    // Full width bands, stacked; last band takes the leftover pixel.
    for (vps) |v| try testing.expectEqual(@as(i32, 500), v.width);
    try testing.expectEqual(@as(i32, 1001 - 250 * 3), vps[3].height); // 251
}

// ── Vertical columns ───────────────────────────────────────────────────────

test "vertical 2-way splits into left/right halves" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(800, 600, 2, .vertical, &buf);
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 400, .height = 600 }, vps[0]);
    try testing.expectEqual(Viewport{ .x = 400, .y = 0, .width = 400, .height = 600 }, vps[1]);
}

test "vertical 3-way tiles exactly with the remainder in the last column" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(1000, 720, 3, .vertical, &buf);
    try expectTilesExactly(vps, 1000, 720);
    for (vps) |v| try testing.expectEqual(@as(i32, 720), v.height);
}

// ── Grid ────────────────────────────────────────────────────────────────────

test "grid 4-way is a 2x2 that tiles exactly" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(800, 600, 4, .grid, &buf);
    try testing.expectEqual(@as(usize, 4), vps.len);
    try expectTilesExactly(vps, 800, 600);
    // Row-major placement: TL, TR, BL, BR.
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 400, .height = 300 }, vps[0]);
    try testing.expectEqual(Viewport{ .x = 400, .y = 0, .width = 400, .height = 300 }, vps[1]);
    try testing.expectEqual(Viewport{ .x = 0, .y = 300, .width = 400, .height = 300 }, vps[2]);
    try testing.expectEqual(Viewport{ .x = 400, .y = 300, .width = 400, .height = 300 }, vps[3]);
}

test "grid 2-way is a single top row of two cells" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(800, 600, 2, .grid, &buf);
    // 1 row, 2 cols → each full height.
    try expectTilesExactly(vps, 800, 600);
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 400, .height = 600 }, vps[0]);
    try testing.expectEqual(Viewport{ .x = 400, .y = 0, .width = 400, .height = 600 }, vps[1]);
}

test "grid 3-way places three cells of a 2x2, leaving the last empty" {
    var buf: [4]Viewport = undefined;
    const vps = splitScreen(800, 600, 3, .grid, &buf);
    try testing.expectEqual(@as(usize, 3), vps.len);
    // TL, TR, BL — the BR cell is intentionally unused.
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 400, .height = 300 }, vps[0]);
    try testing.expectEqual(Viewport{ .x = 400, .y = 0, .width = 400, .height = 300 }, vps[1]);
    try testing.expectEqual(Viewport{ .x = 0, .y = 300, .width = 400, .height = 300 }, vps[2]);
    // The three occupied cells cover 3/4 of the screen.
    var total: i64 = 0;
    for (vps) |v| total += cvp.area(v);
    try testing.expectEqual(@as(i64, 800 * 600 / 4 * 3), total);
}

// ── Viewport helpers ─────────────────────────────────────────────────────────

test "fullscreen / isEmpty / area helpers" {
    const fs = cvp.fullscreen(640, 480);
    try testing.expectEqual(Viewport{ .x = 0, .y = 0, .width = 640, .height = 480 }, fs);
    try testing.expect(!cvp.isEmpty(fs));
    try testing.expectEqual(@as(i64, 640 * 480), cvp.area(fs));

    try testing.expect(cvp.isEmpty(.{ .x = 0, .y = 0, .width = 0, .height = 100 }));
    try testing.expect(cvp.isEmpty(.{}));
    try testing.expectEqual(@as(i64, 0), cvp.area(.{}));
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Assert the rects cover the whole `w × h` screen with no overlap: every
/// pixel belongs to exactly one rect. O(w·h) but the test sizes are small.
fn expectTilesExactly(vps: []const Viewport, w: i32, h: i32) !void {
    // Total area must equal the screen (necessary condition).
    var total: i64 = 0;
    for (vps) |v| total += cvp.area(v);
    try testing.expectEqual(@as(i64, w) * @as(i64, h), total);

    // No two rects overlap (sufficient with the area check → exact cover).
    for (vps, 0..) |a, i| {
        for (vps[i + 1 ..]) |b| {
            const overlap_x = @max(0, @min(a.x + a.width, b.x + b.width) - @max(a.x, b.x));
            const overlap_y = @max(0, @min(a.y + a.height, b.y + b.height) - @max(a.y, b.y));
            try testing.expectEqual(@as(i32, 0), overlap_x * overlap_y);
        }
    }
}
