//! Cross-process pixel ring backed by POSIX shared memory.
//!
//! Layout: a single `shm_open`-d region containing
//!
//!     [ Header (cacheline-aligned) ]
//!     [ Slot 0 pixel bytes (stride * height) ]
//!     [ Slot 1 pixel bytes ... ]
//!     [ Slot N-1 pixel bytes ]
//!
//! The producer (engine) claims a slot, writes, and publishes the slot
//! index via `Header.latest`. The consumer (editor in labelle-gui)
//! reads `latest` (mailbox semantics — always grab the freshest, drop
//! older).
//!
//! Each slot also carries a monotonic `frame_idx` and a producer-stamped
//! `produce_ns` timestamp so the consumer can compute end-to-end latency.
//!
//! Validated end-to-end at 1280x720@60 with raw-IPC p50=5µs / p99=40µs
//! and zero drops in the matched-FPS bench (see imgui-preview-poc/
//! experiments/bench/ — both macOS native and aarch64 ubuntu Docker
//! came within 5% on throughput).
//!
//! Pairs with the PIE-viewport handshake (#543) and is driven from
//! `Preview.beginFrameStream` / `publishFrame` / `endFrameStream`
//! (this file is the implementation; that file is the protocol API).
//!
//! Targets macOS and linux. Windows would use `CreateFileMappingW` —
//! out of scope; see labelle-gui#110 for the cross-platform follow-up.

const std = @import("std");
const builtin = @import("builtin");

pub const PIXEL_FORMAT_RGBA8: u32 = 0x52474241; // 'RGBA'
pub const MAGIC: u64 = 0x4C424C5052564653; // 'LBLPRVFS' — labelle preview frame stream
pub const PROTOCOL_VERSION: u32 = 1;

pub const Error = error{
    ShmOpenFailed,
    FtruncateFailed,
    MmapFailed,
    FstatFailed,
    BadMagic,
    BadVersion,
    TooSmall,
};

/// Cacheline-aligned header. Field layout is a stable ABI across the
/// two processes; do not reorder.
pub const Header = extern struct {
    magic: u64,
    version: u32,
    pixel_format: u32,
    width: u32,
    height: u32,
    stride: u32,
    ring_size: u32,
    /// Slot byte size, including any trailing padding to the next
    /// cacheline. `slot_offset(i) = header_size + i * slot_size`.
    slot_size: u64,
    /// Index of the most-recently published slot. Producer writes,
    /// consumer reads. Single-writer / single-reader; no atomics
    /// needed on the surface (writer fences with full memory barrier
    /// before publishing — see `Producer.publish`).
    latest: u32,
    /// Monotonic counter of frames published since the producer
    /// started. Used by the consumer to detect "new frame available."
    frame_count: u64,
    /// Set non-zero by either side when shutting down. The other
    /// side polls and exits its loop.
    shutdown: u32,
    /// Trailing pad so `@sizeOf(Header) == 64`. With the natural
    /// 8-byte alignment slop between `latest` and `frame_count`, the
    /// fields above end at byte 60 — so 4 bytes of explicit padding
    /// brings the struct to one cacheline.
    _pad: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) % 64 == 0);
}

/// Per-slot side-band: stamped by the producer when the slot is
/// published. The PoC stuffs this into the last few bytes of the slot
/// rather than carrying a separate trailer array, since the slot has
/// guaranteed padding (rounded up to cacheline).
pub const SlotTrailer = extern struct {
    frame_idx: u64,
    produce_ns: u64, // CLOCK_MONOTONIC nanoseconds at publish
    _pad: [48]u8,
};

comptime {
    std.debug.assert(@sizeOf(SlotTrailer) == 64);
}

pub const Options = struct {
    width: u32,
    height: u32,
    /// 2 or 3 — 2 is sufficient for single-writer / single-reader at
    /// 60 Hz; 3 buys a little jitter tolerance.
    ring_size: u32 = 3,
};

/// Path used for `shm_open`. On macOS this must start with `/` and be
/// ≤ `PSHMNAMLEN` (typically 31 chars).
pub const default_name: [:0]const u8 = "/imgui-preview-poc";

/// Compute the slot size (pixel bytes + trailer, padded to cacheline).
pub fn slotSize(width: u32, height: u32) u64 {
    const raw: u64 = @as(u64, width) * @as(u64, height) * 4 + @sizeOf(SlotTrailer);
    return std.mem.alignForward(u64, raw, 64);
}

pub fn totalSize(opts: Options) u64 {
    return @sizeOf(Header) + @as(u64, opts.ring_size) * slotSize(opts.width, opts.height);
}

/// Wall-clock monotonic nanoseconds — used for the latency stamp.
pub fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

/// Cross-platform `fstat`-equivalent that just returns the file size in bytes.
///
/// macOS exposes `std.c.fstat` as a real libc binding; on Linux 0.16 the
/// `std.c.fstat` slot is `void` (the libc binding was removed in favour of
/// `statx`), so we route through the raw syscall there. The consumer only
/// needs the byte size to size its mmap, hence this narrow shim rather than
/// porting the full `Stat` struct.
fn fdSize(fd: std.c.fd_t) !u64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const empty: [*:0]const u8 = "";
        const mask: linux.STATX = .{ .SIZE = true };
        const rc = linux.statx(@intCast(fd), empty, linux.AT.EMPTY_PATH, mask, &sx);
        // `usize` syscall return: errors are -4096..-1 (i.e. very large usize).
        if (@as(isize, @bitCast(rc)) < 0) return Error.FstatFailed;
        return sx.size;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return Error.FstatFailed;
        return @intCast(st.size);
    }
}

// ── Producer ───────────────────────────────────────────────────────

pub const Producer = struct {
    base: [*]u8,
    total_size: usize,
    header: *Header,
    opts: Options,
    fd: std.c.fd_t,
    name: [:0]const u8,
    /// Slot the producer is currently writing into. Rotates 0 → ring-1.
    next_slot: u32 = 0,

    /// Create + truncate + map the shm region. Sets `Header.magic`,
    /// dimensions, ring_size, slot_size. Caller can call `pixelsPtr`
    /// to write into the current slot, then `publish` to advance
    /// `latest` and bump `frame_count`.
    pub fn init(name: [:0]const u8, opts: Options) !Producer {
        const total = totalSize(opts);

        // Best-effort cleanup of any stale region from a previous run.
        // On macOS, `ftruncate` on a POSIX shm object only succeeds once
        // (at creation). A leftover from a crashed run will refuse to
        // resize and we'd fail with `FtruncateFailed`. `shm_unlink` is
        // the only safe escape hatch; if no stale region exists it's a
        // no-op (ENOENT) and we proceed to a fresh shm_open below.
        // On linux this is also harmless: shm_unlink + shm_open(CREAT)
        // gets us a fresh inode either way, matching prior behaviour.
        _ = std.c.shm_unlink(name.ptr);

        // O_RDWR | O_CREAT (no O_EXCL — reattach is fine).
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
        const flags_int: c_int = @bitCast(flags);
        const fd: std.c.fd_t = @intCast(std.c.shm_open(name.ptr, flags_int, @as(std.c.mode_t, 0o600)));
        if (fd < 0) return Error.ShmOpenFailed;
        errdefer _ = std.c.close(fd);

        // ftruncate always — handles both fresh-create and reattach-with-different-size.
        if (std.c.ftruncate(fd, @intCast(total)) != 0) {
            return Error.FtruncateFailed;
        }

        const prot: std.c.PROT = .{ .READ = true, .WRITE = true };
        const map_flags: std.c.MAP = .{ .TYPE = .SHARED };
        const raw = std.c.mmap(null, @intCast(total), prot, map_flags, fd, 0);
        if (raw == std.c.MAP_FAILED) return Error.MmapFailed;
        const base: [*]u8 = @ptrCast(@alignCast(raw));
        errdefer _ = std.c.munmap(@ptrCast(@alignCast(base)), @intCast(total));

        const header: *Header = @ptrCast(@alignCast(base));
        header.* = .{
            .magic = MAGIC,
            .version = PROTOCOL_VERSION,
            .pixel_format = PIXEL_FORMAT_RGBA8,
            .width = opts.width,
            .height = opts.height,
            .stride = opts.width * 4,
            .ring_size = opts.ring_size,
            .slot_size = slotSize(opts.width, opts.height),
            // Sentinel meaning "no slot published yet" — consumers gate on
            // `latest < ring_size`.
            .latest = opts.ring_size,
            .frame_count = 0,
            .shutdown = 0,
            ._pad = [_]u8{0} ** 4,
        };

        return .{
            .base = base,
            .total_size = @intCast(total),
            .header = header,
            .opts = opts,
            .fd = fd,
            .name = name,
            .next_slot = 0,
        };
    }

    pub fn deinit(self: *Producer) void {
        _ = std.c.munmap(@ptrCast(@alignCast(self.base)), self.total_size);
        _ = std.c.close(self.fd);
        // Best-effort: producer owns the lifecycle; remove the name.
        _ = std.c.shm_unlink(self.name.ptr);
        self.base = undefined;
        self.header = undefined;
    }

    /// Returns the pixel bytes pointer for the *next* slot to fill.
    /// Producer writes RGBA8 pixels here (width*height*4 bytes), then
    /// calls `publish`.
    pub fn pixelsPtr(self: *Producer) [*]u8 {
        const slot_base = self.base + @sizeOf(Header) + @as(usize, @intCast(self.next_slot)) * @as(usize, @intCast(self.header.slot_size));
        return slot_base;
    }

    /// Returns the trailer pointer for the slot returned by the last
    /// `pixelsPtr` call. Producer may stamp `frame_idx` and
    /// `produce_ns` directly OR call `publish(stamp_now=true)`.
    pub fn trailerPtr(self: *Producer) *SlotTrailer {
        const slot_base = self.base + @sizeOf(Header) + @as(usize, @intCast(self.next_slot)) * @as(usize, @intCast(self.header.slot_size));
        const trailer_offset: usize = @as(usize, @intCast(self.header.slot_size)) - @sizeOf(SlotTrailer);
        return @ptrCast(@alignCast(slot_base + trailer_offset));
    }

    /// Publish the current slot. With `stamp_now=true` (the default)
    /// the trailer is written here with the current `nowNs()`; if the
    /// producer wants to stamp earlier (e.g. before GPU sync), pass
    /// `stamp_now=false` and write the trailer manually.
    pub fn publish(self: *Producer, stamp_now: bool) void {
        const new_frame_idx = self.header.frame_count + 1;
        if (stamp_now) {
            const trailer = self.trailerPtr();
            trailer.frame_idx = new_frame_idx;
            trailer.produce_ns = nowNs();
        }

        // Release-store `latest` first so any consumer that reads it has a
        // happens-before on the pixel writes + trailer. Then release-store
        // `frame_count` — consumer acquire-loads frame_count first, so the
        // ordering is: consumer sees new frame_count → acquire-load latest
        // → guaranteed to see the slot writes.
        @atomicStore(u32, &self.header.latest, self.next_slot, .release);
        @atomicStore(u64, &self.header.frame_count, new_frame_idx, .release);

        self.next_slot = (self.next_slot + 1) % self.header.ring_size;
    }
};

// ── Consumer ───────────────────────────────────────────────────────

pub const Consumer = struct {
    base: [*]u8,
    total_size: usize,
    header: *Header,
    name: [:0]const u8,
    fd: std.c.fd_t,
    last_seen_frame: u64 = 0,

    /// Open + map an existing shm region created by the producer.
    /// Validates `Header.magic` and `version`.
    pub fn init(name: [:0]const u8) !Consumer {
        const flags: std.c.O = .{ .ACCMODE = .RDWR };
        const flags_int: c_int = @bitCast(flags);
        const fd: std.c.fd_t = @intCast(std.c.shm_open(name.ptr, flags_int, @as(std.c.mode_t, 0)));
        if (fd < 0) return Error.ShmOpenFailed;
        errdefer _ = std.c.close(fd);

        const size_bytes = try fdSize(fd);
        if (size_bytes < @sizeOf(Header)) return Error.TooSmall;
        const total: usize = @intCast(size_bytes);

        const prot: std.c.PROT = .{ .READ = true, .WRITE = true };
        const map_flags: std.c.MAP = .{ .TYPE = .SHARED };
        const raw = std.c.mmap(null, total, prot, map_flags, fd, 0);
        if (raw == std.c.MAP_FAILED) return Error.MmapFailed;
        const base: [*]u8 = @ptrCast(@alignCast(raw));
        errdefer _ = std.c.munmap(@ptrCast(@alignCast(base)), total);

        const header: *Header = @ptrCast(@alignCast(base));
        if (header.magic != MAGIC) return Error.BadMagic;
        if (header.version != PROTOCOL_VERSION) return Error.BadVersion;

        return .{
            .base = base,
            .total_size = total,
            .header = header,
            .name = name,
            .fd = fd,
            .last_seen_frame = 0,
        };
    }

    pub fn deinit(self: *Consumer) void {
        _ = std.c.munmap(@ptrCast(@alignCast(self.base)), self.total_size);
        _ = std.c.close(self.fd);
        // Do NOT shm_unlink — producer owns the lifecycle.
        self.base = undefined;
        self.header = undefined;
    }

    pub const Frame = struct {
        pixels: [*]const u8,
        width: u32,
        height: u32,
        stride: u32,
        frame_idx: u64,
        produce_ns: u64,
    };

    /// Returns the latest unread frame, or null if none new since last
    /// `latest` call. Mailbox semantics: only the most-recent frame is
    /// returned; older un-consumed frames are dropped.
    pub fn latest(self: *Consumer) ?Frame {
        // Acquire-load frame_count first — pairs with the release-store in
        // publish, ensuring we observe latest + slot bytes that were
        // committed before this counter bump.
        const fc = @atomicLoad(u64, &self.header.frame_count, .acquire);
        if (fc <= self.last_seen_frame) return null;

        const slot = @atomicLoad(u32, &self.header.latest, .acquire);
        if (slot >= self.header.ring_size) return null; // sentinel: never published

        const ring_size = self.header.ring_size;
        const slot_size: usize = @intCast(self.header.slot_size);
        const slot_base = self.base + @sizeOf(Header) + @as(usize, slot) * slot_size;
        const trailer: *const SlotTrailer = @ptrCast(@alignCast(slot_base + slot_size - @sizeOf(SlotTrailer)));

        const frame_idx = trailer.frame_idx;
        const produce_ns = trailer.produce_ns;

        // Race guard: if the producer is mid-publish on the same slot we just
        // looked at (slot index wraps every `ring_size` frames), the trailer
        // could be torn. We compare against last_seen_frame as a coarse
        // monotonicity check.
        if (frame_idx <= self.last_seen_frame) return null;

        self.last_seen_frame = frame_idx;
        _ = ring_size;
        return .{
            .pixels = slot_base,
            .width = self.header.width,
            .height = self.header.height,
            .stride = self.header.stride,
            .frame_idx = frame_idx,
            .produce_ns = produce_ns,
        };
    }
};

// ── Shutdown signaling ─────────────────────────────────────────────

pub fn signalShutdown(header: *Header) void {
    @atomicStore(u32, &header.shutdown, 1, .seq_cst);
}

pub fn isShuttingDown(header: *const Header) bool {
    // `@atomicLoad` requires a mutable pointer in older Zig; cast away const.
    const mut: *u32 = @constCast(&header.shutdown);
    return @atomicLoad(u32, mut, .seq_cst) != 0;
}

// ── Tests ──────────────────────────────────────────────────────────

test "totalSize layout sanity" {
    const opts: Options = .{ .width = 64, .height = 32, .ring_size = 3 };
    const slot = slotSize(64, 32);
    try std.testing.expect(slot >= 64 * 32 * 4 + @sizeOf(SlotTrailer));
    try std.testing.expect(slot % 64 == 0);
    try std.testing.expectEqual(@as(u64, @sizeOf(Header) + 3 * slot), totalSize(opts));
}

test "header is cacheline-aligned and stable size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SlotTrailer));
}

test "producer/consumer round-trip" {
    // Use a test-only name so we don't collide with a running game.
    const name: [:0]const u8 = "/imgui-preview-poc-test";
    // Best-effort cleanup from any prior aborted run.
    _ = std.c.shm_unlink(name.ptr);

    var producer = try Producer.init(name, .{ .width = 4, .height = 4, .ring_size = 2 });
    defer producer.deinit();

    var consumer = try Consumer.init(name);
    defer consumer.deinit();

    // Before any publish, latest() returns null (sentinel).
    try std.testing.expect(consumer.latest() == null);

    // Write a recognisable pattern, then publish.
    const pixels = producer.pixelsPtr();
    var i: usize = 0;
    while (i < 4 * 4 * 4) : (i += 1) pixels[i] = @intCast(i & 0xFF);
    producer.publish(true);

    const frame = consumer.latest() orelse return error.NoFrame;
    try std.testing.expectEqual(@as(u32, 4), frame.width);
    try std.testing.expectEqual(@as(u32, 4), frame.height);
    try std.testing.expectEqual(@as(u32, 16), frame.stride);
    try std.testing.expectEqual(@as(u64, 1), frame.frame_idx);
    try std.testing.expect(frame.produce_ns > 0);
    try std.testing.expectEqual(@as(u8, 0), frame.pixels[0]);
    try std.testing.expectEqual(@as(u8, 7), frame.pixels[7]);

    // Second call returns null (no new frame).
    try std.testing.expect(consumer.latest() == null);

    // Publish another, ensure consumer sees it.
    producer.publish(true);
    const frame2 = consumer.latest() orelse return error.NoFrame2;
    try std.testing.expectEqual(@as(u64, 2), frame2.frame_idx);

    // Shutdown signaling.
    try std.testing.expect(!isShuttingDown(producer.header));
    signalShutdown(producer.header);
    try std.testing.expect(isShuttingDown(producer.header));
}
