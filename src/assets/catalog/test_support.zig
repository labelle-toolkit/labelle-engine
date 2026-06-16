//! Shared test fixtures for the AssetCatalog test suites.
//!
//! Splitting `catalog.zig` into focused test files (lifecycle, pump,
//! release) leaves several fixtures shared across them — the mock
//! image backend, the result-ring spin helper, the cross-platform
//! sleep shim, and the dummy `@embedFile`-style byte slices. They live
//! here so each test file imports one module instead of duplicating
//! the bookkeeping.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const engine = @import("engine.zig");

pub const AssetCatalog = engine.AssetCatalog;
pub const AssetState = engine.AssetState;
pub const LoaderKind = engine.LoaderKind;
pub const DecodedPayload = engine.DecodedPayload;
pub const UploadedResource = engine.UploadedResource;
pub const Texture = engine.Texture;
pub const UPLOAD_BUDGET_PER_FRAME = engine.UPLOAD_BUDGET_PER_FRAME;

pub const image_loader = @import("../loaders/image.zig");
pub const DecodedImage = image_loader.DecodedImage;
pub const ImageBackend = image_loader.ImageBackend;

pub fn sleepNs(ns: u64) void {
    if (builtin.os.tag == .windows) {
        const K = struct {
            extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
        };
        K.Sleep(@intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u32))));
        return;
    }
    var req: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem: std.c.timespec = undefined;
    while (true) {
        const rc = std.c.nanosleep(&req, &rem);
        if (rc == 0) return;
        req = rem;
    }
}

pub const dummy_bytes: []const u8 = "PNG-fake-bytes";
pub const dummy_file_type: [:0]const u8 = "png";

// ---------------------------------------------------------------------
// pump() / release() mock backend (#442, #446)
// ---------------------------------------------------------------------
//
// A module-scoped mock backend for the image loader so each test can
// tune `decode_fails` / `upload_fails` independently. `testing.allocator`
// is a GPA under the hood, so a leaked CPU buffer or a double-free on
// any path below will fail the test.

pub const PumpMock = struct {
    pub var decode_calls: u32 = 0;
    pub var upload_calls: u32 = 0;
    pub var unload_calls: u32 = 0;
    pub var next_tex: Texture = 500;
    pub var decode_fails: bool = false;
    pub var upload_fails: bool = false;

    pub fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        next_tex = 500;
        decode_fails = false;
        upload_fails = false;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedImage {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        if (decode_fails) return error.PumpMockDecodeError;
        // 1×1 RGBA — tiny enough to keep the tests fast, big enough
        // that `testing.allocator` catches a leak if `drop` / upload
        // forget to free.
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0xCD);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(decoded: DecodedImage) anyerror!Texture {
        _ = decoded;
        upload_calls += 1;
        if (upload_fails) return error.PumpMockUploadError;
        const t = next_tex;
        next_tex += 1;
        return t;
    }

    fn unloadFn(texture: Texture) void {
        _ = texture;
        unload_calls += 1;
    }

    pub const backend_value: ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

/// Spin until the worker has published `at_least` results onto the
/// result ring or a 200ms deadline elapses. The worker parks for
/// ~100µs between empty polls so this is fine-grained enough for
/// tests but never a busy-wait in production.
pub fn spinForResults(catalog: *AssetCatalog, at_least: u32) !void {
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        // Non-atomic peek across all result rings — safe here because
        // the test is the sole consumer and each worker is the sole
        // producer of its own ring. `pump()` would normally race us
        // for these slots.
        var total: u32 = 0;
        for (&catalog.results) |*ring| {
            const head = ring.head.load(.acquire);
            const tail = ring.tail.load(.acquire);
            total += head -% tail;
        }
        if (total >= at_least) return;
        sleepNs(step_ns);
    }
    return error.WorkerDidNotRespond;
}
