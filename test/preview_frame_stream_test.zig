//! Tests for the PIE viewport SHM frame stream (#544): the
//! producer side of the embedded-viewport pipeline. Exercises
//! `Preview.beginFrameStream` / `publishFrame` / `endFrameStream`
//! end-to-end by spinning up an in-test `preview_shm.Consumer`
//! against the SHM region the engine allocates.
//!
//! The actual PBO → CPU readback lives in each backend (raylib,
//! sokol, …); this file covers only the engine-side API. PoC end-
//! to-end with a real GL producer is in
//! `imgui-preview-poc/src/{game,editor}.zig`.

const std = @import("std");
const engine = @import("engine");
const preview = engine.preview_mode_mod;
const shm = engine.preview_mode_mod.preview_shm;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowMs() i64 {
    const CLOCK_MONOTONIC: c_int = if (@import("builtin").os.tag == .macos) 6 else 1;
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

// ── Loopback harness (same shape as preview_handshake_test) ────────

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

// Reads the `frame_offer` JSON the engine emitted and returns the
// parsed shm_name + dims, so the test's `shm.Consumer` knows where
// to attach.
const Offer = struct {
    shm_name: [:0]u8,
    width: u32,
    height: u32,
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
    // shm_name needs to outlive the arena — caller owns the dupe.
    const dup = try std.testing.allocator.dupeZ(u8, parsed.shm_name);
    return .{
        .shm_name = dup,
        .width = parsed.width,
        .height = parsed.height,
        .ring_size = parsed.ring_size,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "beginFrameStream emits frame_offer + leaves producer in .offered" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(320, 240);
    try std.testing.expectEqual(preview.FrameHandshakeState.offered, p.frame_state);

    const offer = try readOffer(&h);
    defer std.testing.allocator.free(offer.shm_name);
    try std.testing.expectEqual(@as(u32, 320), offer.width);
    try std.testing.expectEqual(@as(u32, 240), offer.height);
    try std.testing.expectEqual(@as(u32, 3), offer.ring_size);
    // SHM name must start with `/` (POSIX shm_open requirement).
    try std.testing.expect(offer.shm_name[0] == '/');
}

test "publishFrame writes pixels into the SHM ring; consumer reads them back" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(64, 48);
    const offer = try readOffer(&h);
    defer std.testing.allocator.free(offer.shm_name);

    // Editor side: open the consumer ring.
    var consumer = try shm.Consumer.init(offer.shm_name);
    defer consumer.deinit();

    // Editor ACKs the offer; engine state flips to .accepted.
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    // Synthesize a frame whose first 4 bytes are 0xDE 0xAD 0xBE 0xEF
    // and the rest a known gradient. publishFrame must memcpy + publish.
    const N: usize = 64 * 48 * 4;
    const pixels = try std.testing.allocator.alloc(u8, N);
    defer std.testing.allocator.free(pixels);
    pixels[0] = 0xDE;
    pixels[1] = 0xAD;
    pixels[2] = 0xBE;
    pixels[3] = 0xEF;
    for (4..N) |i| pixels[i] = @intCast(i & 0xff);

    try p.publishFrame(pixels);

    // Consumer reads the published frame and verifies content.
    const frame = consumer.latest() orelse return error.NoFrameFound;
    try std.testing.expectEqual(@as(u64, 1), frame.frame_idx);
    try std.testing.expectEqual(@as(u32, 64), frame.width);
    try std.testing.expectEqual(@as(u32, 48), frame.height);
    try std.testing.expectEqual(@as(u8, 0xDE), frame.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), frame.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0xBE), frame.pixels[2]);
    try std.testing.expectEqual(@as(u8, 0xEF), frame.pixels[3]);
    try std.testing.expectEqual(@as(u8, 100 & 0xff), frame.pixels[100]);
}

test "publishFrame returns StreamNotActive when state is .offered (editor hasn't accepted)" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(8, 8);
    var drop_buf: [512]u8 = undefined;
    _ = try h.readLine(&drop_buf);
    // State is .offered, NOT .accepted — publish must refuse.
    var pixels: [8 * 8 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.StreamNotActive, p.publishFrame(&pixels));
}

test "publishFrame returns StreamNotActive when called without beginFrameStream" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    var pixels: [4]u8 = undefined;
    try std.testing.expectError(error.StreamNotActive, p.publishFrame(&pixels));
}

test "beginFrameStream resets frame_state even when re-offer is in progress" {
    // Regression for #546 review: a failed re-offer path used to leave
    // `frame_state == .accepted` while `frame_producer == null`, which
    // made `isFrameAccepted()` lie to the backend. Here we exercise the
    // happy-path re-offer cycle and assert that *during* the
    // re-offer (after teardown but before sendFrameOffer lands) the
    // state is invalidated.
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(8, 8);
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);
    try std.testing.expect(p.isFrameAccepted());

    // Force a re-offer (same shape as the resize path). After
    // beginFrameStream returns, state should be `.offered` (the
    // freshly-sent offer awaits the next accept). What we're really
    // proving: state is **not** stuck at `.accepted` carrying over
    // from the previous handshake — sendFrameOffer is the only thing
    // that can flip us to `.offered` post-teardown.
    try p.beginFrameStream(16, 16);
    try std.testing.expectEqual(preview.FrameHandshakeState.offered, p.frame_state);
    try std.testing.expect(!p.isFrameAccepted());
}

test "publishFrame returns InvalidFrameSize when buffer size mismatches dims" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(8, 8);
    var drop_buf: [512]u8 = undefined;
    _ = try h.readLine(&drop_buf);
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    // Negotiated dims are 8×8×4 = 256 bytes — pass 100 to provoke
    // the size guard. Distinct from StreamNotActive so callers can
    // tell "no editor attached" from "wrong number of bytes."
    var pixels: [100]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.InvalidFrameSize, p.publishFrame(&pixels));
}

test "publishFrame increments frame_idx monotonically across multiple publishes" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(4, 4);
    const offer = try readOffer(&h);
    defer std.testing.allocator.free(offer.shm_name);

    var consumer = try shm.Consumer.init(offer.shm_name);
    defer consumer.deinit();

    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitUntil(&p, isAccepted, 1000);

    var pixels: [4 * 4 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try p.publishFrame(&pixels);
    try p.publishFrame(&pixels);
    try p.publishFrame(&pixels);

    const frame = consumer.latest() orelse return error.NoFrameFound;
    // Mailbox semantics: consumer sees only the latest. frame_idx
    // bumps once per publish — third publish is frame_idx == 3.
    try std.testing.expectEqual(@as(u64, 3), frame.frame_idx);
}

test "beginFrameStream after frame_resize re-offers at new dims, old ring is torn down" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(16, 16);
    const first_offer = try readOffer(&h);
    defer std.testing.allocator.free(first_offer.shm_name);
    try std.testing.expectEqual(@as(u32, 16), first_offer.width);

    // Editor requests a resize.
    try h.sendLine("{\"kind\":\"frame_resize\",\"width\":32,\"height\":24}\n");
    try waitUntil(&p, struct {
        fn pred(pv: *preview.Preview) bool { return pv.pending_resize != null; }
    }.pred, 1000);

    const r = p.takeResize().?;
    try std.testing.expectEqual(@as(u32, 32), r.width);

    // Backend re-offers at the new dims; first ring's shm is gone now.
    try p.beginFrameStream(r.width, r.height);
    const second_offer = try readOffer(&h);
    defer std.testing.allocator.free(second_offer.shm_name);
    try std.testing.expectEqual(@as(u32, 32), second_offer.width);
    try std.testing.expectEqual(@as(u32, 24), second_offer.height);
    // The two SHM names should differ — each beginFrameStream call
    // increments the per-process stream-id counter, so resize-
    // re-offer cycles never collide on the shm_open namespace.
    try std.testing.expect(!std.mem.eql(u8, first_offer.shm_name, second_offer.shm_name));
}

test "endFrameStream tears down ring, subsequent publishFrame is StreamNotActive" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.beginFrameStream(8, 8);
    var drop_buf: [512]u8 = undefined;
    _ = try h.readLine(&drop_buf);

    p.endFrameStream();
    try std.testing.expectEqual(preview.FrameHandshakeState.not_offered, p.frame_state);

    var pixels: [8 * 8 * 4]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expectError(error.StreamNotActive, p.publishFrame(&pixels));
}
