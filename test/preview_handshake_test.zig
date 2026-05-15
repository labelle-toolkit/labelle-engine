//! Tests for the PIE viewport handshake (#543): `frame_offer`,
//! `frame_accept`, `frame_resize`, `frame_published` shape +
//! state-machine transitions on the `Preview` struct.
//!
//! Lives in its own file (separate from `preview_mode_test.zig`)
//! to keep handshake coverage cohesive. preview_mode_test.zig is
//! re-enabled in this PR — the same variadic-fcntl ABI fix that
//! unblocked the handshake tests also unblocked its 21 previously-
//! disabled subscription-flow tests, so the split is now purely
//! organisational, not a gate.

const std = @import("std");
const engine = @import("engine");
const preview = engine.preview_mode_mod;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;

// ── Loopback harness ───────────────────────────────────────────────
//
// Mirrors the (currently-disabled) harness in preview_mode_test.zig.
// Bound to 127.0.0.1:0, port discovered via getsockname.

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
        const port = std.mem.bigToNative(u16, sa.port);
        return .{ .server = server, .port = port };
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

    /// Read a newline-terminated JSON line (the engine → editor frame).
    /// Returns the body without the trailing `\n`.
    fn readLine(self: *LoopbackHarness, out: []u8) ![]const u8 {
        while (true) {
            // Look for an existing newline in the buffered bytes.
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

    /// Push a complete editor → engine frame (caller supplies the `\n`).
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

const Timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;

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

/// Polls `Preview.pollSubscription` in a tight loop until `predicate`
/// returns true or `deadline_ms` elapses. Mirrors the
/// `waitForSubscription` pattern in the disabled preview_mode_test
/// — TCP loopback delivery isn't synchronous, so a single poll right
/// after the harness `write` won't always see the bytes.
fn waitFor(p: *preview.Preview, predicate: *const fn (*preview.Preview) bool, deadline_ms: u64) !void {
    const start = nowMs();
    while (true) {
        try p.pollSubscription();
        if (predicate(p)) return;
        if (nowMs() - start > @as(i64, @intCast(deadline_ms))) return error.WaitForDeadlineExceeded;
        sleepMs(1);
    }
}

fn isAccepted(p: *preview.Preview) bool {
    return p.isFrameAccepted();
}

fn hasResize(p: *preview.Preview) bool {
    return p.pending_resize != null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "sendFrameOffer serializes expected JSON and flips state to offered" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try std.testing.expectEqual(preview.FrameHandshakeState.not_offered, p.frame_state);

    try p.sendFrameOffer(.{
        .shm_name = "/labelle-preview-42",
        .width = 1280,
        .height = 720,
        .format = .rgba8,
        .ring_size = 3,
        .slot_size_bytes = 3_686_464,
    });

    try std.testing.expectEqual(preview.FrameHandshakeState.offered, p.frame_state);

    var line_buf: [512]u8 = undefined;
    const line = try h.readLine(&line_buf);
    // Sanity: round-trip parse + spot-check fields. The exact key
    // ordering is Zig std.json's choice; assert by parse, not by
    // byte-equal compare.
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
    try std.testing.expectEqualStrings("/labelle-preview-42", parsed.shm_name);
    try std.testing.expectEqual(@as(u32, 1280), parsed.width);
    try std.testing.expectEqual(@as(u32, 720), parsed.height);
    try std.testing.expectEqualStrings("rgba8", parsed.format);
    try std.testing.expectEqual(@as(u32, 3), parsed.ring_size);
    try std.testing.expectEqual(@as(u64, 3_686_464), parsed.slot_size_bytes);
}

test "sendFramePublished carries frame_idx and produce_ns" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.sendFramePublished(42, 1_234_567_890);

    var buf: [256]u8 = undefined;
    const line = try h.readLine(&buf);
    const Parsed = struct { kind: []const u8, frame_idx: u64, produce_ns: u64 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Parsed, arena.allocator(), line, .{});
    try std.testing.expectEqualStrings("frame_published", parsed.kind);
    try std.testing.expectEqual(@as(u64, 42), parsed.frame_idx);
    try std.testing.expectEqual(@as(u64, 1_234_567_890), parsed.produce_ns);
}

test "frame_accept transitions offered → accepted; isFrameAccepted reports it" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.sendFrameOffer(.{
        .shm_name = "/labelle-preview-test",
        .width = 320,
        .height = 240,
        .slot_size_bytes = 320 * 240 * 4 + 64,
    });
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);

    try std.testing.expect(!p.isFrameAccepted());
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitFor(&p, isAccepted, 1000);
    try std.testing.expectEqual(preview.FrameHandshakeState.accepted, p.frame_state);
}

test "frame_accept from not_offered is ignored (no spurious transition)" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    // Drain the inbox: poll until the bytes have been consumed (the
    // frame_accept handler is a no-op in this state, so we can't
    // observe a state change — wait for the inbox to drain instead).
    const start = nowMs();
    while (nowMs() - start <= 200) {
        try p.pollSubscription();
        if (p.inbox.items.len == 0) break;
        sleepMs(1);
    }
    try std.testing.expectEqual(@as(usize, 0), p.inbox.items.len);
    try std.testing.expectEqual(preview.FrameHandshakeState.not_offered, p.frame_state);
}

test "frame_resize sets pending_resize, takeResize pops it once and resets state" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try p.sendFrameOffer(.{
        .shm_name = "/labelle-preview-resize",
        .width = 640,
        .height = 360,
        .slot_size_bytes = 640 * 360 * 4 + 64,
    });
    var drop: [512]u8 = undefined;
    _ = try h.readLine(&drop);
    try h.sendLine("{\"kind\":\"frame_accept\"}\n");
    try waitFor(&p, isAccepted, 1000);

    try std.testing.expect(p.takeResize() == null);

    try h.sendLine("{\"kind\":\"frame_resize\",\"width\":1920,\"height\":1080}\n");
    try waitFor(&p, hasResize, 1000);

    const first = p.takeResize();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(u32, 1920), first.?.width);
    try std.testing.expectEqual(@as(u32, 1080), first.?.height);
    try std.testing.expectEqual(preview.FrameHandshakeState.not_offered, p.frame_state);
    try std.testing.expect(p.takeResize() == null);
}

// Helper that polls until pollSubscription returns the expected error
// or the deadline expires (in which case we propagate "we never saw
// the bytes" as a test failure).
fn expectPollErrorWithin(p: *preview.Preview, expected: anyerror, deadline_ms: u64) !void {
    const start = nowMs();
    while (true) {
        const r = p.pollSubscription();
        if (r) |_| {
            if (nowMs() - start > @as(i64, @intCast(deadline_ms))) return error.DidNotErrorBeforeDeadline;
            sleepMs(1);
            continue;
        } else |err| {
            if (err == expected) return;
            return err;
        }
    }
}

test "frame_resize with missing dim fields surfaces MalformedSubscription" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try h.sendLine("{\"kind\":\"frame_resize\"}\n");
    try expectPollErrorWithin(&p, error.MalformedSubscription, 1000);
}

test "unknown control frame is still rejected (regression guard)" {
    var h = try LoopbackHarness.init();
    defer h.deinit();
    var p = try connectPair(&h);
    defer p.deinit();

    try h.sendLine("{\"kind\":\"frame_who_knows\"}\n");
    try expectPollErrorWithin(&p, error.MalformedSubscription, 1000);
}
