//! Tests for the PIE viewport macOS IOSurface frame stream (#547).
//! Producer is the engine side under test; the consumer half ships
//! in `labelle-gui/src/iosurface.zig`. To avoid a cross-repo build
//! dependency we port a scope-internal consumer in this file (lean
//! version of the labelle-gui code — just enough to look up surfaces
//! by ID, read the ControlBlock back, and inspect pixel bytes via
//! `IOSurfaceGetBaseAddress`).
//!
//! Gated on macOS. On Linux/Windows every test in this file early-
//! returns so the engine's `zig build test` step stays green on every
//! supported host (per ticket: macOS-only test target, cross-platform
//! stub).

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const preview = engine.preview_mode_mod;
const shm = engine.preview_mode_mod.preview_shm;
const iosurface = engine.preview_iosurface_mod;

// ── macOS-only IOSurface externs (only called on macOS — guarded at
// every callsite by `builtin.os.tag == .macos` early returns). Linker
// resolves these via the engine module's frameworks linkage (see
// `build.zig`).

extern "c" fn IOSurfaceLookup(csid: iosurface.IOSurfaceID) iosurface.IOSurfaceRef;
extern "c" fn IOSurfaceGetBaseAddress(buffer: iosurface.IOSurfaceRef) ?*anyopaque;
extern "c" fn IOSurfaceGetWidth(buffer: iosurface.IOSurfaceRef) usize;
extern "c" fn IOSurfaceGetHeight(buffer: iosurface.IOSurfaceRef) usize;
extern "c" fn IOSurfaceGetBytesPerRow(buffer: iosurface.IOSurfaceRef) usize;
extern "c" fn IOSurfaceLock(buffer: iosurface.IOSurfaceRef, options: u32, seed: ?*u32) c_int;
extern "c" fn IOSurfaceUnlock(buffer: iosurface.IOSurfaceRef, options: u32, seed: ?*u32) c_int;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowMs() i64 {
    // CLOCK_MONOTONIC == 6 on macOS, 1 on Linux. Both branches valid
    // because the routine is only used inside macOS-gated tests; the
    // Linux value is here purely so the file compiles cross-platform.
    const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;
    var ts: Timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    const ts: Timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}

// ── In-test consumer (a slim port of labelle-gui's consumer). Lives
// here on purpose — we don't want to widen the engine's public
// surface with a consumer half; that's the editor's job.

const TestConsumer = struct {
    shm_consumer: shm.Consumer,
    surfaces: [iosurface.MAX_RING]iosurface.IOSurfaceRef = [_]iosurface.IOSurfaceRef{null} ** iosurface.MAX_RING,
    ring_size: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    bytes_per_row: u32 = 0,
    slot_size: usize = 0,
    last_seen_frame: u64 = 0,

    fn init(shm_name: [:0]const u8) !TestConsumer {
        var sc = try shm.Consumer.init(shm_name);
        errdefer sc.deinit();

        const ctrl: *const iosurface.ControlBlock =
            @ptrCast(@alignCast(sc.base + @sizeOf(shm.Header)));
        if (@atomicLoad(u64, @constCast(&ctrl.magic), .acquire) != iosurface.ControlBlock.MAGIC) {
            return error.ControlBlockMissing;
        }
        const ring_size = ctrl.ring_size;
        const width = ctrl.width;
        const height = ctrl.height;
        const pixel_format = ctrl.pixel_format;
        if (ring_size == 0 or ring_size > iosurface.MAX_RING) return error.RingSizeOutOfRange;
        if (pixel_format != iosurface.kPixelFormat_BGRA8) return error.PixelFormatMismatch;

        var surfaces: [iosurface.MAX_RING]iosurface.IOSurfaceRef =
            [_]iosurface.IOSurfaceRef{null} ** iosurface.MAX_RING;
        var looked_up: u32 = 0;
        errdefer {
            var i: u32 = 0;
            while (i < looked_up) : (i += 1) {
                if (surfaces[i]) |s| CFRelease(@ptrCast(s));
            }
        }
        while (looked_up < ring_size) : (looked_up += 1) {
            const id = ctrl.ids[looked_up];
            const ref = IOSurfaceLookup(id) orelse return error.IOSurfaceLookupFailed;
            surfaces[looked_up] = ref;
        }
        const bpr: u32 = @intCast(IOSurfaceGetBytesPerRow(surfaces[0].?));
        const slot_size: usize = @intCast(sc.header.slot_size);
        return .{
            .shm_consumer = sc,
            .surfaces = surfaces,
            .ring_size = ring_size,
            .width = width,
            .height = height,
            .bytes_per_row = bpr,
            .slot_size = slot_size,
        };
    }

    fn deinit(self: *TestConsumer) void {
        var i: u32 = 0;
        while (i < self.ring_size) : (i += 1) {
            if (self.surfaces[i]) |s| CFRelease(@ptrCast(s));
            self.surfaces[i] = null;
        }
        self.shm_consumer.deinit();
    }

    const Frame = struct {
        surface: iosurface.IOSurfaceRef,
        slot: u32,
        frame_idx: u64,
    };

    fn latest(self: *TestConsumer) ?Frame {
        const fc = @atomicLoad(u64, &self.shm_consumer.header.frame_count, .acquire);
        if (fc <= self.last_seen_frame) return null;
        const slot = @atomicLoad(u32, &self.shm_consumer.header.latest, .acquire);
        if (slot >= self.ring_size) return null;
        const slot_base = self.shm_consumer.base + @sizeOf(shm.Header) +
            @as(usize, slot) * self.slot_size;
        const trailer: *const shm.SlotTrailer =
            @ptrCast(@alignCast(slot_base + self.slot_size - @sizeOf(shm.SlotTrailer)));
        const frame_idx = trailer.frame_idx;
        if (frame_idx <= self.last_seen_frame) return null;
        self.last_seen_frame = frame_idx;
        return .{
            .surface = self.surfaces[slot],
            .slot = slot,
            .frame_idx = frame_idx,
        };
    }
};

// ── Loopback harness (same shape as preview_frame_stream_test) ─────

const LoopbackHarness = struct {
    server: std.Io.net.Server,
    port: u16,
    conn_fd: ?std.posix.fd_t = null,
    read_buf: [4096]u8 = undefined,
    read_len: usize = 0,

    fn init() !LoopbackHarness {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
        const server = try addr.listen(std.testing.io, .{ .reuse_address = true });
        var sa: std.posix.sockaddr.in = undefined;
        var sa_len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
        if (std.posix.system.getsockname(server.socket.handle, @ptrCast(&sa), &sa_len) != 0) {
            return error.GetSockNameFailed;
        }
        return .{ .server = server, .port = std.mem.bigToNative(u16, sa.port) };
    }

    fn deinit(self: *LoopbackHarness) void {
        if (self.conn_fd) |fd| _ = close(@intCast(fd));
        self.server.deinit(std.testing.io);
    }

    fn hostPort(self: *LoopbackHarness, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{self.port});
    }

    fn accept(self: *LoopbackHarness) !void {
        const stream = try self.server.accept(std.testing.io);
        self.conn_fd = stream.socket.handle;
    }

    fn readLine(self: *LoopbackHarness, out: []u8) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.read_buf[0..self.read_len], '\n')) |nl| {
                if (nl > out.len) return error.LineTooLong;
                @memcpy(out[0..nl], self.read_buf[0..nl]);
                const remaining = self.read_len - (nl + 1);
                std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[nl + 1 .. self.read_len]);
                self.read_len = remaining;
                return out[0..nl];
            }
            if (self.read_len == self.read_buf.len) return error.LineTooLong;
            const fd = self.conn_fd orelse return error.NotConnected;
            const n = read(@intCast(fd), self.read_buf[self.read_len..].ptr, self.read_buf.len - self.read_len);
            if (n <= 0) return error.UnexpectedEof;
            self.read_len += @intCast(n);
        }
    }

    fn sendLine(self: *LoopbackHarness, body: []const u8) !void {
        const fd = self.conn_fd orelse return error.NotConnected;
        var off: usize = 0;
        while (off < body.len) {
            const n = write(@intCast(fd), body.ptr + off, body.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }
};

fn connectPair(h: *LoopbackHarness) !preview.Preview {
    var hp_buf: [64]u8 = undefined;
    const host_port = try h.hostPort(&hp_buf);
    const p = try preview.Preview.connect(std.testing.io, std.testing.allocator, host_port);
    try h.accept();
    return p;
}

fn waitUntil(p: *preview.Preview, predicate: *const fn (*preview.Preview) bool, deadline_ms: u64) !void {
    const start = nowMs();
    while (true) {
        try p.pollSubscription();
        if (predicate(p)) return;
        if (nowMs() - start > @as(i64, @intCast(deadline_ms))) return error.WaitDeadlineExceeded;
        sleepMs(1);
    }
}

fn isAccepted(p: *preview.Preview) bool {
    return p.isFrameAccepted();
}

const Offer = struct {
    shm_name: [:0]u8,
    width: u32,
    height: u32,
    format: []u8, // owned
    ring_size: u32,
};

fn readOffer(h: *LoopbackHarness) !Offer {
    var line_buf: [512]u8 = undefined;
    const line = try h.readLine(&line_buf);
    const Parsed = struct {
        kind: []const u8,
        shm_name: []const u8,
        width: u32,
        height: u32,
        format: []const u8,
        ring_size: u32,
        slot_size_bytes: u64,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Parsed, arena.allocator(), line, .{});
    try std.testing.expectEqualStrings("frame_offer", parsed.kind);
    return .{
        .shm_name = try std.testing.allocator.dupeZ(u8, parsed.shm_name),
        .width = parsed.width,
        .height = parsed.height,
        .format = try std.testing.allocator.dupe(u8, parsed.format),
        .ring_size = parsed.ring_size,
    };
}

fn freeOffer(o: Offer) void {
    std.testing.allocator.free(o.shm_name);
    std.testing.allocator.free(o.format);
}

// ── Tests ──────────────────────────────────────────────────────────

test "beginFrameStreamIOSurface emits frame_offer with iosurface_bgra8 format" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(64, 48);
    try std.testing.expectEqual(preview.FrameHandshakeState.offered, p.frame_state);

    const offer = try readOffer(&h);
    defer freeOffer(offer);
    try std.testing.expectEqual(@as(u32, 64), offer.width);
    try std.testing.expectEqual(@as(u32, 48), offer.height);
    try std.testing.expectEqual(@as(u32, 3), offer.ring_size);
    try std.testing.expectEqualStrings("iosurface_bgra8", offer.format);
    try std.testing.expect(offer.shm_name[0] == '/');
}

test "in-test Consumer attaches, sees ControlBlock, looks up every surface" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(32, 32);
    const offer = try readOffer(&h);
    defer freeOffer(offer);

    var consumer = try TestConsumer.init(offer.shm_name);
    defer consumer.deinit();
    try std.testing.expectEqual(@as(u32, 3), consumer.ring_size);
    try std.testing.expectEqual(@as(u32, 32), consumer.width);
    try std.testing.expectEqual(@as(u32, 32), consumer.height);
    // Every surface in the ring must have looked up successfully —
    // `init` would have errored if any slot was null.
    var i: u32 = 0;
    while (i < consumer.ring_size) : (i += 1) {
        try std.testing.expect(consumer.surfaces[i] != null);
    }
    // bytes_per_row may be > width * 4 due to kernel-imposed
    // alignment; equality isn't promised, but it must be at least
    // width * 4.
    try std.testing.expect(consumer.bytes_per_row >= 32 * 4);
}

test "publishFrameIOSurface writes pixels (RGBA→BGRA swizzle); consumer reads them back" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(16, 16);
    const offer = try readOffer(&h);
    defer freeOffer(offer);

    var consumer = try TestConsumer.init(offer.shm_name);
    defer consumer.deinit();

    // Editor ACKs the offer; engine state flips to .accepted.
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    // Build an RGBA8 buffer with a recognisable first pixel
    // (R=0xDE G=0xAD B=0xBE A=0xEF); the producer swizzles to BGRA8.
    const W: u32 = 16;
    const H: u32 = 16;
    const N: usize = W * H * 4;
    const pixels = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(pixels);
    pixels[0] = 0xDE;
    pixels[1] = 0xAD;
    pixels[2] = 0xBE;
    pixels[3] = 0xEF;
    for (4..N) |i| pixels[i] = @intCast(i & 0xff);

    try p.publishFrameIOSurface(pixels);

    const frame = consumer.latest() orelse return error.NoFrameFound;
    try std.testing.expectEqual(@as(u64, 1), frame.frame_idx);

    // Lock the surface read-only to inspect the bytes. After the
    // swizzle, byte[0] = B = 0xBE, byte[1] = G = 0xAD, byte[2] = R = 0xDE,
    // byte[3] = A = 0xEF.
    const lr = IOSurfaceLock(frame.surface, 0x1, null);
    try std.testing.expectEqual(@as(c_int, 0), lr);
    defer _ = IOSurfaceUnlock(frame.surface, 0x1, null);
    const base_opt = IOSurfaceGetBaseAddress(frame.surface);
    const base: [*]const u8 = @ptrCast(base_opt orelse return error.BaseAddressNull);
    try std.testing.expectEqual(@as(u8, 0xBE), base[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), base[1]);
    try std.testing.expectEqual(@as(u8, 0xDE), base[2]);
    try std.testing.expectEqual(@as(u8, 0xEF), base[3]);

    // Check the swizzle for a second pixel too (offset 4..7).
    // pixels[4]=4 (R), pixels[5]=5 (G), pixels[6]=6 (B), pixels[7]=7 (A)
    // → base[4]=6 (B), base[5]=5 (G), base[6]=4 (R), base[7]=7 (A)
    try std.testing.expectEqual(@as(u8, 6), base[4]);
    try std.testing.expectEqual(@as(u8, 5), base[5]);
    try std.testing.expectEqual(@as(u8, 4), base[6]);
    try std.testing.expectEqual(@as(u8, 7), base[7]);
}

test "publishFrameIOSurface returns StreamNotActive when editor hasn't accepted" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(8, 8);
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);
    var pixels: [8 * 8 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.StreamNotActive, p.publishFrameIOSurface(&pixels));
}

test "publishFrameIOSurface returns InvalidFrameSize on wrong buffer size" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(8, 8);
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    var pixels: [100]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.InvalidFrameSize, p.publishFrameIOSurface(&pixels));
}

test "publishFrameIOSurface increments frame_idx monotonically" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(4, 4);
    const offer = try readOffer(&h);
    defer freeOffer(offer);
    var consumer = try TestConsumer.init(offer.shm_name);
    defer consumer.deinit();
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    var pixels: [4 * 4 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try p.publishFrameIOSurface(&pixels);
    try p.publishFrameIOSurface(&pixels);
    try p.publishFrameIOSurface(&pixels);

    const frame = consumer.latest() orelse return error.NoFrameFound;
    try std.testing.expectEqual(@as(u64, 3), frame.frame_idx);
}

test "endFrameStreamIOSurface tears down ring; subsequent publish is StreamNotActive" {
    if (builtin.os.tag != .macos) return;
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStreamIOSurface(8, 8);
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);
    p.endFrameStreamIOSurface();
    try std.testing.expectEqual(preview.FrameHandshakeState.not_offered, p.frame_state);

    var pixels: [8 * 8 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.StreamNotActive, p.publishFrameIOSurface(&pixels));
}

test "SHM and IOSurface modes are mutually exclusive on the same Preview" {
    if (builtin.os.tag != .macos) return;

    // SHM first, then IOSurface — must reject.
    {
        var h = try LoopbackHarness.init();
        defer h.deinit();
        var p = try connectPair(&h);
        defer p.deinit();

        try p.beginFrameStream(8, 8);
        var drop: [512]u8 = undefined;
        _ = try h.readLine(&drop);
        try std.testing.expectError(error.WrongFrameMode, p.beginFrameStreamIOSurface(8, 8));
    }

    // IOSurface first, then SHM — must also reject.
    {
        var h = try LoopbackHarness.init();
        defer h.deinit();
        var p = try connectPair(&h);
        defer p.deinit();

        try p.beginFrameStreamIOSurface(8, 8);
        var drop: [512]u8 = undefined;
        _ = try h.readLine(&drop);
        try std.testing.expectError(error.WrongFrameMode, p.beginFrameStream(8, 8));
    }
}
