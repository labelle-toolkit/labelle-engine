/// Tests for `preview_mode.zig` — connect-out control channel for
/// the labelle-gui editor (#516).
///
/// We exercise `Preview` in-process against a loopback `std.net.Server`
/// rather than spawning a subprocess: the engine is a library with no
/// `main()` of its own, and the bytes-on-the-wire correctness is what
/// matters here. The Phase 1 follow-up that *does* spawn the
/// assembled binary will live editor-side in labelle-gui.
const std = @import("std");
const engine = @import("engine");
const preview_mode = engine.preview_mode_mod;

const Preview = preview_mode.Preview;
const ByeReason = preview_mode.ByeReason;

test "parseArgs: returns null when flag is absent" {
    const argv = [_][]const u8{ "game", "--scene=main" };
    try std.testing.expect(preview_mode.parseArgs(&argv) == null);
}

test "parseArgs: returns host:port for space form" {
    const argv = [_][]const u8{ "game", "--preview-mode", "127.0.0.1:54321", "--scene=main" };
    const result = preview_mode.parseArgs(&argv) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("127.0.0.1:54321", result);
}

test "parseArgs: returns host:port for equals form" {
    const argv = [_][]const u8{ "game", "--preview-mode=127.0.0.1:54321" };
    const result = preview_mode.parseArgs(&argv) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("127.0.0.1:54321", result);
}

test "parseArgs: bare flag at end of argv returns null" {
    const argv = [_][]const u8{ "game", "--preview-mode" };
    try std.testing.expect(preview_mode.parseArgs(&argv) == null);
}

test "Preview: connect rejects malformed host:port" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidAddress, Preview.connect(allocator, "not-a-host-port"));
}

// ── Loopback round-trip ─────────────────────────────────────────────

const LoopbackHarness = struct {
    server: std.net.Server,
    port: u16,
    conn: ?std.net.Server.Connection = null,
    /// Newline-framing buffer.
    read_buf: [4096]u8 = undefined,
    read_len: usize = 0,

    fn init() !LoopbackHarness {
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        var server = try addr.listen(.{ .reuse_address = true });
        const port = server.listen_address.getPort();
        return .{ .server = server, .port = port };
    }

    fn deinit(self: *LoopbackHarness) void {
        if (self.conn) |c| c.stream.close();
        self.server.deinit();
    }

    fn hostPort(self: *LoopbackHarness, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{self.port});
    }

    fn accept(self: *LoopbackHarness) !void {
        self.conn = try self.server.accept();
    }

    /// Read one `\n`-terminated frame into `out`. Blocks until a
    /// newline arrives. Returns the JSON body without the trailing
    /// `\n`.
    fn readFrame(self: *LoopbackHarness, out: []u8) ![]const u8 {
        const stream = self.conn.?.stream;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.read_buf[0..self.read_len], '\n')) |nl| {
                if (nl > out.len) return error.FrameTooLarge;
                @memcpy(out[0..nl], self.read_buf[0..nl]);
                const remaining = self.read_len - nl - 1;
                std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[nl + 1 .. self.read_len]);
                self.read_len = remaining;
                return out[0..nl];
            }
            const n = try stream.read(self.read_buf[self.read_len..]);
            if (n == 0) return error.EndOfStream;
            self.read_len += n;
        }
    }
};

test "Preview: hello round-trip over loopback TCP" {
    const allocator = std.testing.allocator;

    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try preview.sendHello("1.34.0-spike", 12345);

    var frame_buf: [512]u8 = undefined;
    const frame = try harness.readFrame(&frame_buf);

    const Parsed = struct {
        kind: []const u8,
        engine_version: []const u8,
        pid: i32,
        protocol_version: u32,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, frame, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", parsed.value.kind);
    try std.testing.expectEqualStrings("1.34.0-spike", parsed.value.engine_version);
    try std.testing.expectEqual(@as(i32, 12345), parsed.value.pid);
    try std.testing.expectEqual(preview_mode.protocol_version, parsed.value.protocol_version);
}

test "Preview: heartbeats arrive at the listener in order" {
    const allocator = std.testing.allocator;

    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try preview.sendHeartbeat(1000);
    try preview.sendHeartbeat(1250);

    const Parsed = struct { kind: []const u8, t: u64 };

    var frame_buf: [256]u8 = undefined;
    {
        const frame = try harness.readFrame(&frame_buf);
        const parsed = try std.json.parseFromSlice(Parsed, allocator, frame, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("heartbeat", parsed.value.kind);
        try std.testing.expectEqual(@as(u64, 1000), parsed.value.t);
    }
    {
        const frame = try harness.readFrame(&frame_buf);
        const parsed = try std.json.parseFromSlice(Parsed, allocator, frame, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("heartbeat", parsed.value.kind);
        try std.testing.expectEqual(@as(u64, 1250), parsed.value.t);
    }
}

test "Preview: tickHeartbeat respects the rate limit" {
    const allocator = std.testing.allocator;

    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    // First call always emits (last_heartbeat_ms == 0).
    try preview.tickHeartbeat(1000);
    // Below the interval — must NOT emit.
    try preview.tickHeartbeat(1100);
    try preview.tickHeartbeat(1200);
    // At/above the interval — must emit.
    try preview.tickHeartbeat(1250);

    const Parsed = struct { kind: []const u8, t: u64 };

    var frame_buf: [256]u8 = undefined;
    const first = try harness.readFrame(&frame_buf);
    const first_parsed = try std.json.parseFromSlice(Parsed, allocator, first, .{});
    defer first_parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1000), first_parsed.value.t);

    const second = try harness.readFrame(&frame_buf);
    const second_parsed = try std.json.parseFromSlice(Parsed, allocator, second, .{});
    defer second_parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1250), second_parsed.value.t);
}

test "Preview: full lifecycle — hello, heartbeats, bye, EOF" {
    const allocator = std.testing.allocator;

    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var preview = try Preview.connect(allocator, host_port);
    try harness.accept();

    try preview.sendHello("test", 42);
    try preview.sendHeartbeat(100);
    try preview.sendHeartbeat(350);
    try preview.sendBye(.normal);
    preview.deinit();

    var frame_buf: [512]u8 = undefined;
    // hello
    {
        const f = try harness.readFrame(&frame_buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"hello\"") != null);
    }
    // heartbeat 1
    {
        const f = try harness.readFrame(&frame_buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"heartbeat\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"t\":100") != null);
    }
    // heartbeat 2
    {
        const f = try harness.readFrame(&frame_buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"t\":350") != null);
    }
    // bye
    {
        const f = try harness.readFrame(&frame_buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"bye\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"reason\":\"normal\"") != null);
    }
    // After bye + deinit, the server side must observe a clean EOF.
    harness.read_len = 0;
    var eof_buf: [16]u8 = undefined;
    const n = try harness.conn.?.stream.read(&eof_buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "Preview: bye produces wire bytes the editor can parse" {
    // Guards against accidental enum-value drift on the wire — the
    // editor side parses the literal strings.
    const allocator = std.testing.allocator;
    const Msg = struct {
        kind: []const u8 = "bye",
        reason: []const u8,
    };
    const cases = [_]struct { reason: ByeReason, expected: []const u8 }{
        .{ .reason = .normal, .expected = "{\"kind\":\"bye\",\"reason\":\"normal\"}" },
        .{ .reason = .crashed, .expected = "{\"kind\":\"bye\",\"reason\":\"crashed\"}" },
        .{ .reason = .killed, .expected = "{\"kind\":\"bye\",\"reason\":\"killed\"}" },
    };
    inline for (cases) |c| {
        const out = try std.json.Stringify.valueAlloc(allocator, Msg{ .reason = c.reason.asString() }, .{});
        defer allocator.free(out);
        try std.testing.expectEqualStrings(c.expected, out);
    }
}
