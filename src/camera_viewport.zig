//! Camera viewport layout — split-screen composition math (#761 Phase 3).
//!
//! The renderer-agnostic half of the deferred camera-bound-layers work. RFC
//! #723 Phase 1 (per-layer camera binding by tag) shipped in gfx 1.26;
//! Phase 2 (a bound layer renders into a declared viewport rect) and Phase 3
//! (N cameras × viewport = split-screen / minimap / PiP) need the renderer
//! to make `setViewport` real across backends and to compose several
//! cameras per frame — that lives in `labelle-gfx`. This module owns the
//! part that does NOT: the pure geometry that turns "screen size + how many
//! views + which layout" into the set of screen-space `Viewport` rects the
//! renderer then draws each camera into.
//!
//! Keeping it here (engine-side, renderer-free) matches `camera.zig`'s
//! stance that `Viewport` is an engine-local rect that deliberately does not
//! reference gfx's `ScreenViewport`: the engine computes the layout, the gfx
//! binding consumes it. It's also directly testable without any backend —
//! the layouts tile the screen exactly (no uncovered gap, no overlap on the
//! full-grid cases), which is the invariant a split-screen composition
//! depends on.
//!
//! Remaining #761 work (gfx repo, out of this module): real `setViewport`
//! per bound layer, wiring the declarative layer→camera binding to feed
//! these rects, and the per-camera scissor in the render loop.

const std = @import("std");
const camera = @import("camera.zig");

/// Engine-local screen-space rect (re-exported from `camera.zig` so callers
/// have one `Viewport` type across the camera surface).
pub const Viewport = camera.Viewport;

/// A full-screen viewport for a `w × h` screen. The identity layout for a
/// single camera (equivalent to `Camera.viewport == null`).
pub fn fullscreen(w: i32, h: i32) Viewport {
    return .{ .x = 0, .y = 0, .width = w, .height = h };
}

/// `true` when the rect has no area — the "unset / fullscreen" sentinel a
/// zero-initialized or partially-authored `Viewport` carries.
pub fn isEmpty(v: Viewport) bool {
    return v.width <= 0 or v.height <= 0;
}

/// Rect area as `i64` (avoids i32 overflow on large screens).
pub fn area(v: Viewport) i64 {
    if (isEmpty(v)) return 0;
    return @as(i64, v.width) * @as(i64, v.height);
}

/// How to divide the screen among N cameras.
pub const SplitLayout = enum {
    /// Horizontal bands, full width, stacked top→bottom (classic 2-player
    /// co-op / racing split). Always tiles the screen exactly.
    horizontal,
    /// Vertical columns, full height, left→right. Always tiles exactly.
    vertical,
    /// Row-major 2-column grid (top→bottom, left→right), up to 4 views. A
    /// count that fills the grid (1, 2, 4) tiles exactly; an odd count (3)
    /// leaves the trailing cell empty (the conventional 3-player look).
    grid,
};

/// Compute `count` screen-space viewport rects tiling a `screen_w ×
/// screen_h` screen for `layout`, writing them into `out` and returning the
/// filled prefix. `count` is clamped to `out.len` (pass a buffer at least as
/// large as the number of cameras — `[4]Viewport` covers the split-screen
/// maximum). Screen origin is top-left (gfx convention): band/row 0 is at
/// the top, column 0 at the left.
///
/// For `horizontal`/`vertical` the integer-division remainder is folded into
/// the LAST band/column so the rects cover every pixel with no seam. `count
/// == 0` returns an empty slice; `count == 1` is always the full screen
/// regardless of layout.
pub fn splitScreen(
    screen_w_in: i32,
    screen_h_in: i32,
    count: usize,
    layout: SplitLayout,
    out: []Viewport,
) []Viewport {
    // Clamp negative screen dimensions to 0 so no rect can carry a negative
    // width/height into the renderer (which panics / mis-scissors on one) —
    // a degenerate empty screen yields empty viewports rather than garbage.
    const screen_w = @max(0, screen_w_in);
    const screen_h = @max(0, screen_h_in);
    const n = @min(count, out.len);
    if (n == 0) return out[0..0];
    if (n == 1) {
        out[0] = fullscreen(screen_w, screen_h);
        return out[0..1];
    }

    switch (layout) {
        .horizontal => {
            const ni: i32 = @intCast(n);
            const band = @divTrunc(screen_h, ni);
            var y: i32 = 0;
            for (0..n) |i| {
                // Last band absorbs the remainder so the stack reaches the
                // bottom edge exactly.
                const h = if (i == n - 1) screen_h - y else band;
                out[i] = .{ .x = 0, .y = y, .width = screen_w, .height = h };
                y += band;
            }
        },
        .vertical => {
            const ni: i32 = @intCast(n);
            const col = @divTrunc(screen_w, ni);
            var x: i32 = 0;
            for (0..n) |i| {
                const w = if (i == n - 1) screen_w - x else col;
                out[i] = .{ .x = x, .y = 0, .width = w, .height = screen_h };
                x += col;
            }
        },
        .grid => {
            // 2 columns, as many rows as needed (n ≤ 4 → 1 or 2 rows).
            const cols: i32 = 2;
            const rows: i32 = @intCast((n + 1) / 2);
            const cell_w = @divTrunc(screen_w, cols);
            const cell_h = @divTrunc(screen_h, rows);
            for (0..n) |i| {
                const ci: i32 = @intCast(i % 2);
                const ri: i32 = @intCast(i / 2);
                // Right column / bottom row absorb the remainder so a
                // full grid (2 or 4) tiles exactly.
                const w = if (ci == cols - 1) screen_w - cell_w * ci else cell_w;
                const h = if (ri == rows - 1) screen_h - cell_h * ri else cell_h;
                out[i] = .{ .x = cell_w * ci, .y = cell_h * ri, .width = w, .height = h };
            }
        },
    }
    return out[0..n];
}
