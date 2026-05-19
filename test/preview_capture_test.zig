//! Tests for the `FrameCapture` trait and the `publishFrame` orchestration
//! in `src/preview_capture.zig`. Validates the backend-agnostic preview
//! architecture end-to-end on the producer side — no real backend, no
//! sokol, no GPU. The trait + producer chain alone should be enough to
//! get correct pixels into the SHM ring.

const std = @import("std");
const engine = @import("engine");
const preview_capture = engine.preview_capture_mod;
const preview_shm = engine.preview_mode_mod.preview_shm;
const testing = std.testing;

test "publishFrame writes RGBA8 checkerboard into producer slot" {
    // Real SHM region — names namespaced by PID + per-test tag so the
    // three tests in this file don't collide within one `zig build test`.
    const pid = std.c.getpid();
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/lbl-fctA-{d}", .{pid});

    var producer = try preview_shm.Producer.init(name, .{
        .width = 8,
        .height = 4,
        .ring_size = 2,
    });
    defer producer.deinit();

    var checker: preview_capture.CheckerboardCapture = .{ .cell = 2 };
    try preview_capture.publishFrame(&producer, checker.frameCapture(), true);

    // Read slot 0 directly from the SHM region.
    const header_size = @sizeOf(preview_shm.Header);
    const slot0_pixels = producer.base[header_size .. header_size + 8 * 4 * 4];

    // Pixel (0,0) at frame 0: cx=0, cy=0, parity 0 → DARK (red-tinted).
    try testing.expectEqual(@as(u8, 64), slot0_pixels[0]);
    try testing.expectEqual(@as(u8, 0), slot0_pixels[1]);
    try testing.expectEqual(@as(u8, 0), slot0_pixels[2]);
    try testing.expectEqual(@as(u8, 255), slot0_pixels[3]);

    // Pixel (2,0): cx=1, cy=0, parity 1 → LIT (white).
    const px20 = 2 * 4;
    try testing.expectEqual(@as(u8, 255), slot0_pixels[px20 + 0]);
    try testing.expectEqual(@as(u8, 255), slot0_pixels[px20 + 1]);
    try testing.expectEqual(@as(u8, 255), slot0_pixels[px20 + 2]);

    try testing.expectEqual(@as(u32, 1), checker.frame_index);
}

test "second publishFrame writes a shifted pattern into the next slot" {
    const pid = std.c.getpid();
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/lbl-fctB-{d}", .{pid});

    var producer = try preview_shm.Producer.init(name, .{
        .width = 8,
        .height = 4,
        .ring_size = 2,
    });
    defer producer.deinit();

    var checker: preview_capture.CheckerboardCapture = .{ .cell = 2 };
    try preview_capture.publishFrame(&producer, checker.frameCapture(), true);
    try preview_capture.publishFrame(&producer, checker.frameCapture(), true);

    // Slot 0 → frame 0; slot 1 → frame 1 (frame_index shift).
    //
    // Pixel (1,0):
    //   Frame 0: cx=(1+0)/2=0, cy=0 → DARK
    //   Frame 1: cx=(1+1)/2=1, cy=0 → LIT
    const header_size = @sizeOf(preview_shm.Header);
    const slot_pixel_bytes: usize = 8 * 4 * 4;
    const slot_size_in_shm: usize = @intCast(producer.header.slot_size);
    const slot0_pixels = producer.base[header_size .. header_size + slot_pixel_bytes];
    const slot1_pixels = producer.base[header_size + slot_size_in_shm .. header_size + slot_size_in_shm + slot_pixel_bytes];

    try testing.expectEqual(@as(u8, 64), slot0_pixels[1 * 4 + 0]); // DARK
    try testing.expectEqual(@as(u8, 255), slot1_pixels[1 * 4 + 0]); // LIT

    try testing.expectEqual(@as(u32, 2), checker.frame_index);
}

test "publishFrame propagates capture errors" {
    const pid = std.c.getpid();
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/lbl-fctC-{d}", .{pid});

    var producer = try preview_shm.Producer.init(name, .{
        .width = 4,
        .height = 4,
        .ring_size = 2,
    });
    defer producer.deinit();

    // A FrameCapture that always errors — the engine has to surface it.
    const FailingCapture = struct {
        fn captureImpl(_: *anyopaque, _: []u8, _: u32, _: u32) anyerror!void {
            return error.SimulatedBackendFailure;
        }
    };
    const fc: preview_capture.FrameCapture = .{
        .capture_fn = FailingCapture.captureImpl,
        .ctx = undefined,
    };

    try testing.expectError(error.SimulatedBackendFailure, preview_capture.publishFrame(&producer, fc, true));
}

test "publishFrame returns SizeMismatch when slot capacity shrinks below pixel bytes" {
    const pid = std.c.getpid();
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/lbl-fctD-{d}", .{pid});

    var producer = try preview_shm.Producer.init(name, .{
        .width = 8,
        .height = 4,
        .ring_size = 2,
    });
    defer producer.deinit();

    // Simulate header tampering / post-init opts drift: pretend the
    // producer was reconfigured to a larger frame after the slot was
    // already allocated for an 8x4 layout. publishFrame should refuse
    // before invoking the backend.
    producer.opts.width = 32;
    producer.opts.height = 32;

    // A capture that, if ever invoked, would let the test know we
    // failed to short-circuit before reaching the backend.
    const Tripwire = struct {
        fn captureImpl(_: *anyopaque, _: []u8, _: u32, _: u32) anyerror!void {
            return error.BackendShouldNotHaveBeenCalled;
        }
    };
    const fc: preview_capture.FrameCapture = .{
        .capture_fn = Tripwire.captureImpl,
        .ctx = undefined,
    };

    try testing.expectError(preview_capture.PublishError.SizeMismatch, preview_capture.publishFrame(&producer, fc, true));
}
