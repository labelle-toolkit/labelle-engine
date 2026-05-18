//! Backend-agnostic frame-capture trait for the preview pipeline.
//!
//! The preview module's contract with a backend is exactly one operation:
//! *"write the most-recently-rendered frame's pixels into this buffer"*.
//! Every GPU API exposes that (sokol `sg.queryImagePixels`, raylib
//! `rlReadScreenPixels`, bgfx `readTexture`, wgpu buffer-copy-from-texture,
//! null backend memcpy-from-framebuffer).
//!
//! By collapsing every backend's preview producer down to a single
//! function pointer, the engine's preview code stops needing to know
//! anything about Metal, GL, D3D11, IOSurface, MTLTexture, PBOs, or
//! the per-OS readback dance. Backend authors implement one ~30-line
//! `captureFrame` shim; the engine drives the protocol + SHM ring.
//!
//! Pixel format is **RGBA8** packed, top-to-bottom, no padding:
//! `dst.len == width * height * 4`. The engine validates the slice
//! length before invoking; backend impls don't have to defend against
//! `dst` shorter than expected.

const std = @import("std");
const preview_shm = @import("preview_shm.zig");

/// A backend's contribution to the preview pipeline. One function
/// pointer + opaque context per backend. The engine takes ownership
/// of the calling convention: capture runs on the producer's thread,
/// once per frame, after the backend has finished rendering its
/// swapchain pass.
pub const FrameCapture = struct {
    /// Write the most-recently-rendered frame's pixels into `dst` as
    /// packed RGBA8 with stride = `width * 4`. May return any error;
    /// the engine surfaces capture errors back to the editor as a
    /// `bye` with reason `.capture_failed` (TBD wire-protocol change).
    capture_fn: *const fn (ctx: *anyopaque, dst: []u8, width: u32, height: u32) anyerror!void,

    /// Opaque backend pointer. The engine never dereferences it; it's
    /// passed back verbatim to `capture_fn` on every invocation.
    ctx: *anyopaque,
};

/// Orchestrate one frame: grab the next SHM slot, ask the backend to
/// fill it via `capture`, then publish. The producer's slot dimensions
/// must match the FrameCapture's expected output (this is enforced via
/// the SHM header `width`/`height` set at `Producer.init` time).
///
/// Returns `Error.SizeMismatch` if the slot can't hold a full frame
/// (programmer error in producer setup), otherwise propagates the
/// backend's capture error or `Error.PublishFailed`.
pub const PublishError = error{
    SizeMismatch,
    PublishFailed,
} || std.mem.Allocator.Error;

pub fn publishFrame(producer: *preview_shm.Producer, capture: FrameCapture, stamp_now: bool) anyerror!void {
    const w = producer.opts.width;
    const h = producer.opts.height;
    // The shm Header.slot_size includes padding for trailer bytes; the
    // pixel region is exactly w*h*4. Backend writes only into that.
    const pixel_bytes: usize = @as(usize, w) * @as(usize, h) * 4;
    const slot_ptr = producer.pixelsPtr();
    const dst = slot_ptr[0..pixel_bytes];

    try capture.capture_fn(capture.ctx, dst, w, h);
    producer.publish(stamp_now);
}

/// Mock backend: fills the destination buffer with a deterministic
/// "checkerboard" pattern keyed on `frame_index`. Used by the
/// `test/preview_capture_test.zig` unit tests AND by the standalone
/// preview_mock_game tool in labelle-tools — the same producer-side
/// code path validates the trait without involving any real backend.
pub const CheckerboardCapture = struct {
    frame_index: u32 = 0,
    /// Cell side in pixels. 32 = visible at thumbnail scale.
    cell: u32 = 32,

    pub fn frameCapture(self: *CheckerboardCapture) FrameCapture {
        return .{
            .capture_fn = captureImpl,
            .ctx = @ptrCast(self),
        };
    }

    fn captureImpl(ctx: *anyopaque, dst: []u8, width: u32, height: u32) anyerror!void {
        const self: *CheckerboardCapture = @ptrCast(@alignCast(ctx));
        const expected = @as(usize, width) * @as(usize, height) * 4;
        if (dst.len < expected) return error.SizeMismatch;

        // Light/dark alternates per `cell` pixels in both axes; the
        // `frame_index` shifts the pattern so successive frames are
        // distinguishable (catches "producer overwrote slot N with
        // frame N+1's data while consumer was reading slot N").
        const cell = self.cell;
        const fi = self.frame_index;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const i: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
                const cx = (x +% fi) / cell;
                const cy = y / cell;
                const lit = (cx +% cy) & 1 == 1;
                // RGBA8: R, G, B, A. Light = white, dark = red-tinted
                // so we can see the frame_index advance visually too.
                dst[i + 0] = if (lit) 255 else 64; // R
                dst[i + 1] = if (lit) 255 else 0; // G
                dst[i + 2] = if (lit) 255 else 0; // B
                dst[i + 3] = 255; // A
            }
        }

        self.frame_index +%= 1;
    }
};
