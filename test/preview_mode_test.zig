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
const BinaryFrameKind = preview_mode.BinaryFrameKind;
const binary_magic = preview_mode.binary_magic;

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

    /// Read exactly `n` bytes from the inbound buffer, blocking on
    /// the socket if more is needed. Used by binary-frame readers.
    fn readExact(self: *LoopbackHarness, out: []u8) !void {
        const stream = self.conn.?.stream;
        while (self.read_len < out.len) {
            const n = try stream.read(self.read_buf[self.read_len..]);
            if (n == 0) return error.EndOfStream;
            self.read_len += n;
        }
        @memcpy(out, self.read_buf[0..out.len]);
        const remaining = self.read_len - out.len;
        std.mem.copyForwards(u8, self.read_buf[0..remaining], self.read_buf[out.len..self.read_len]);
        self.read_len = remaining;
    }

    /// Read one binary frame: `[magic][kind][u32 len][payload]`.
    /// Asserts the magic byte. Returns `kind` + a copy of the payload
    /// in `out` (truncated to `out.len`).
    fn readBinaryFrame(self: *LoopbackHarness, out: []u8) !struct { kind: u8, payload: []u8 } {
        var header: [6]u8 = undefined;
        try self.readExact(&header);
        if (header[0] != binary_magic) return error.NotBinaryFrame;
        const kind = header[1];
        const len = std.mem.readInt(u32, header[2..6], .little);
        if (len > out.len) return error.PayloadBufferTooSmall;
        try self.readExact(out[0..len]);
        return .{ .kind = kind, .payload = out[0..len] };
    }

    /// Peek the next byte without consuming. Blocks until at least
    /// one byte is available.
    fn peekByte(self: *LoopbackHarness) !u8 {
        const stream = self.conn.?.stream;
        while (self.read_len == 0) {
            const n = try stream.read(self.read_buf[self.read_len..]);
            if (n == 0) return error.EndOfStream;
            self.read_len += n;
        }
        return self.read_buf[0];
    }

    /// Editor → engine direction: write a newline-terminated JSON
    /// frame to the accepted connection.
    fn writeJsonLine(self: *LoopbackHarness, line: []const u8) !void {
        const stream = self.conn.?.stream;
        try stream.writeAll(line);
        try stream.writeAll("\n");
    }
};

/// Spin until `preview.pollSubscription` reports a non-empty filter
/// set. Bounded so a broken implementation can't hang the test runner.
fn waitForSubscription(preview: *Preview, comp_name: []const u8, deadline_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        try preview.pollSubscription();
        if (preview.isComponentSubscribed(comp_name)) return;
        const now = std.time.milliTimestamp();
        if (now - start > @as(i64, @intCast(deadline_ms))) return error.SubscriptionDeadlineExceeded;
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
}

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

// ── Phase 2 / #518 — binary state telemetry ─────────────────────────

test "emitEntityCreated: writes magic+kind+length+payload with optional prefab name" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try preview.emitEntityCreated(42, "Player");

    var payload_buf: [256]u8 = undefined;
    const frame = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_created), frame.kind);
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, frame.payload[0..8], .little));
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, frame.payload[8..10], .little));
    try std.testing.expectEqualStrings("Player", frame.payload[10..16]);

    // null prefab name → name_len = 0, no name bytes.
    try preview.emitEntityCreated(43, null);
    const frame2 = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_created), frame2.kind);
    try std.testing.expectEqual(@as(u64, 43), std.mem.readInt(u64, frame2.payload[0..8], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, frame2.payload[8..10], .little));
    try std.testing.expectEqual(@as(usize, 10), frame2.payload.len);
}

test "emitEntityDestroyed: writes magic+kind+length+entity_id" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try preview.emitEntityDestroyed(0xDEADBEEF);

    var payload_buf: [64]u8 = undefined;
    const frame = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_destroyed), frame.kind);
    try std.testing.expectEqual(@as(usize, 8), frame.payload.len);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), std.mem.readInt(u64, frame.payload[0..8], .little));
}

test "emitComponentChanged: only emits when component is subscribed" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    // Default: empty subscription set → no traffic.
    try std.testing.expect(!preview.isComponentSubscribed("Position"));
    try preview.emitComponentChanged(1, "Position", "ignored");

    // Subscribe via the editor → engine path.
    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);
    try std.testing.expect(preview.isComponentSubscribed("Position"));

    // Subscribed components ride the wire; the wrong-name path stays silent.
    try preview.emitComponentChanged(7, "Velocity", "still ignored");
    try preview.emitComponentChanged(7, "Position", &[_]u8{ 0x11, 0x22, 0x33, 0x44 });

    var payload_buf: [256]u8 = undefined;
    const frame = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), frame.kind);
    // [u64 entity_id][u16 name_len][name][u32 data_len][data]
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, frame.payload[0..8], .little));
    const name_len = std.mem.readInt(u16, frame.payload[8..10], .little);
    try std.testing.expectEqual(@as(u16, 8), name_len);
    try std.testing.expectEqualStrings("Position", frame.payload[10 .. 10 + name_len]);
    const data_off: usize = 10 + name_len;
    const data_len = std.mem.readInt(u32, frame.payload[data_off..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 4), data_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, frame.payload[data_off + 4 .. data_off + 4 + data_len]);
}

test "pollSubscription: decodes subscribe and unsubscribe from editor" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\",\"Velocity\",\"Health\"]}");
    try waitForSubscription(&preview, "Health", 1000);
    try std.testing.expect(preview.isComponentSubscribed("Position"));
    try std.testing.expect(preview.isComponentSubscribed("Velocity"));
    try std.testing.expect(preview.isComponentSubscribed("Health"));
    try std.testing.expect(!preview.isComponentSubscribed("MissingOne"));

    try harness.writeJsonLine("{\"kind\":\"unsubscribe\",\"components\":[\"Velocity\"]}");
    // Wait until Velocity drops out of the filter set.
    const start = std.time.milliTimestamp();
    while (preview.isComponentSubscribed("Velocity")) {
        try preview.pollSubscription();
        if (std.time.milliTimestamp() - start > 1000) return error.UnsubscribeDeadlineExceeded;
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
    try std.testing.expect(preview.isComponentSubscribed("Position"));
    try std.testing.expect(!preview.isComponentSubscribed("Velocity"));
    try std.testing.expect(preview.isComponentSubscribed("Health"));
}

test "Preview: JSON heartbeats and binary frames multiplex on one socket" {
    // The full Phase 2 wire scenario: editor sends a JSON subscribe,
    // engine answers with binary frames interleaved with JSON
    // heartbeats. Reader-side disambiguates by peeking the first
    // byte (0x1B → binary, otherwise → JSON).
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    // Editor opts in to Position telemetry.
    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);

    // Engine emits an interleaved stream.
    try preview.sendHello("phase2-spike", 99);
    try preview.emitEntityCreated(101, "Goblin");
    try preview.sendHeartbeat(500);
    try preview.emitComponentChanged(101, "Position", &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 });
    try preview.emitEntityDestroyed(101);
    try preview.sendBye(.normal);

    // 1. hello (JSON)
    {
        try std.testing.expect((try harness.peekByte()) != binary_magic);
        var buf: [256]u8 = undefined;
        const f = try harness.readFrame(&buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"hello\"") != null);
    }
    // 2. entity_created (binary)
    {
        try std.testing.expectEqual(binary_magic, try harness.peekByte());
        var buf: [256]u8 = undefined;
        const f = try harness.readBinaryFrame(&buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_created), f.kind);
    }
    // 3. heartbeat (JSON)
    {
        try std.testing.expect((try harness.peekByte()) != binary_magic);
        var buf: [256]u8 = undefined;
        const f = try harness.readFrame(&buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"heartbeat\"") != null);
    }
    // 4. component_changed (binary)
    {
        try std.testing.expectEqual(binary_magic, try harness.peekByte());
        var buf: [256]u8 = undefined;
        const f = try harness.readBinaryFrame(&buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
    }
    // 5. entity_destroyed (binary)
    {
        try std.testing.expectEqual(binary_magic, try harness.peekByte());
        var buf: [256]u8 = undefined;
        const f = try harness.readBinaryFrame(&buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_destroyed), f.kind);
    }
    // 6. bye (JSON)
    {
        try std.testing.expect((try harness.peekByte()) != binary_magic);
        var buf: [256]u8 = undefined;
        const f = try harness.readFrame(&buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"bye\"") != null);
    }
}

test "pollSubscription: malformed JSON surfaces MalformedSubscription" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":\"not-an-array\"}");

    // Spin until the bytes have arrived in the engine's inbox and we
    // can decode them.
    const start = std.time.milliTimestamp();
    while (true) {
        const r = preview.pollSubscription();
        if (r) {
            // No bytes yet — try again.
            if (std.time.milliTimestamp() - start > 1000) return error.NoMalformedFrameSurfaced;
            { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
            continue;
        } else |err| {
            try std.testing.expectEqual(@as(anyerror, error.MalformedSubscription), err);
            break;
        }
    }
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

// ── Phase 2 wiring (#520) — Game ECS lifecycle → Preview ────────────

const Game = engine.Game;

// Lightweight components defined here so their `@typeName` is stable
// (`preview_mode_test.TestPos` / `preview_mode_test.TestSprite`) and
// the subscription filter the test sends matches what the engine
// emits via `@typeName(@TypeOf(component))` in
// `notifyComponentChanged`.
const TestPos = extern struct { x: i32, y: i32 };
const TestSprite = extern struct { sprite_id: u32, visible: u8 };

const BinaryFrameResult = struct { kind: u8, payload: []u8 };

/// Walk to the next binary frame, draining any JSON noise (heartbeats,
/// hello/bye, etc.) the engine emits in between. The Phase 2 wiring
/// only touches binary frames, so JSON traffic mixed in is signal we
/// can safely discard for this assertion path.
fn nextBinaryFrame(
    harness: *LoopbackHarness,
    out: []u8,
) !BinaryFrameResult {
    var scratch: [1024]u8 = undefined;
    while (true) {
        const first = try harness.peekByte();
        if (first == binary_magic) {
            const f = try harness.readBinaryFrame(out);
            return .{ .kind = f.kind, .payload = f.payload };
        }
        _ = try harness.readFrame(&scratch); // drop one JSON line
    }
}

test "Game lifecycle: createEntity + addComponent emit telemetry; destroy + filter respected (#520)" {
    const allocator = std.testing.allocator;

    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);

    var game = Game.init(allocator);
    defer game.deinit();

    game.preview = try Preview.connect(allocator, host_port);
    // Game.deinit cleans up `preview` — no manual deinit here.
    try harness.accept();

    // Phase 1 handshake — hello + heartbeat — proves the JSON plane
    // is alive before binary frames start flowing.
    try (game.preview.?).sendHello("phase2-wiring", 1);
    try (game.preview.?).sendHeartbeat(0);
    {
        var buf: [512]u8 = undefined;
        const f = try harness.readFrame(&buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"hello\"") != null);
    }
    {
        var buf: [256]u8 = undefined;
        const f = try harness.readFrame(&buf);
        try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"heartbeat\"") != null);
    }

    // Editor subscribes to the two component names we'll exercise.
    // The names must match what `@typeName` produces for the types
    // the engine sees in `addComponent`.
    const pos_name = @typeName(TestPos);
    const sprite_name = @typeName(TestSprite);

    var sub_buf: [256]u8 = undefined;
    const sub_line = try std.fmt.bufPrint(
        &sub_buf,
        "{{\"kind\":\"subscribe\",\"components\":[\"{s}\",\"{s}\"]}}",
        .{ pos_name, sprite_name },
    );
    try harness.writeJsonLine(sub_line);
    try waitForSubscription(&game.preview.?, pos_name, 1000);
    try waitForSubscription(&game.preview.?, sprite_name, 1000);

    // Create one entity with both components — expect:
    //   1 × entity_created  (id == 1)
    //   1 × component_changed (TestPos)
    //   1 × component_changed (TestSprite)
    const e1 = game.createEntity();
    game.addComponent(e1, TestPos{ .x = 10, .y = 20 });
    game.addComponent(e1, TestSprite{ .sprite_id = 7, .visible = 1 });

    var payload_buf: [512]u8 = undefined;

    // entity_created(e1)
    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_created), f.kind);
        const id = std.mem.readInt(u64, f.payload[0..8], .little);
        try std.testing.expectEqual(@as(u64, @intCast(e1)), id);
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        // createEntity emits null prefab name → name_len == 0.
        try std.testing.expectEqual(@as(u16, 0), name_len);
    }
    // component_changed(TestPos)
    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        const id = std.mem.readInt(u64, f.payload[0..8], .little);
        try std.testing.expectEqual(@as(u64, @intCast(e1)), id);
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        try std.testing.expectEqualStrings(pos_name, f.payload[10 .. 10 + name_len]);
        const data_off: usize = 10 + name_len;
        const data_len = std.mem.readInt(u32, f.payload[data_off..][0..4], .little);
        try std.testing.expectEqual(@as(u32, @sizeOf(TestPos)), data_len);
        // Recover the x/y the engine handed us through `asBytes`.
        const x = std.mem.readInt(i32, f.payload[data_off + 4 ..][0..4], .little);
        const y = std.mem.readInt(i32, f.payload[data_off + 8 ..][0..4], .little);
        try std.testing.expectEqual(@as(i32, 10), x);
        try std.testing.expectEqual(@as(i32, 20), y);
    }
    // component_changed(TestSprite)
    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        try std.testing.expectEqualStrings(sprite_name, f.payload[10 .. 10 + name_len]);
    }

    // Destroy the entity → expect one entity_destroyed.
    game.destroyEntity(e1);
    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_destroyed), f.kind);
        const id = std.mem.readInt(u64, f.payload[0..8], .little);
        try std.testing.expectEqual(@as(u64, @intCast(e1)), id);
    }

    // Subscription filter: touching a component the editor never
    // subscribed to (and an entity it never asked about) MUST NOT
    // produce a `component_changed` frame. We still expect the
    // `entity_created` frame (lifecycle events bypass the filter),
    // and then the next binary frame after that must be
    // `entity_destroyed` — proving no Unsubscribed-component frame
    // sneaked in between.
    const Unsubscribed = extern struct { v: u32 };
    const e2 = game.createEntity();
    game.addComponent(e2, Unsubscribed{ .v = 99 });

    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_created), f.kind);
        const id = std.mem.readInt(u64, f.payload[0..8], .little);
        try std.testing.expectEqual(@as(u64, @intCast(e2)), id);
    }

    game.destroyEntity(e2);
    {
        const f = try nextBinaryFrame(&harness, &payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.entity_destroyed), f.kind);
        const id = std.mem.readInt(u64, f.payload[0..8], .little);
        try std.testing.expectEqual(@as(u64, @intCast(e2)), id);
    }
}

// ── Phase 3 / #535 — node_entered binary telemetry ──────────────────

/// Spin until the engine reports the given flow as subscribed. Mirror
/// of `waitForSubscription` for the flow opt-in set.
fn waitForFlowSubscription(preview: *Preview, flow_name: []const u8, deadline_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        try preview.pollSubscription();
        if (preview.isFlowSubscribed(flow_name)) return;
        const now = std.time.milliTimestamp();
        if (now - start > @as(i64, @intCast(deadline_ms))) return error.SubscriptionDeadlineExceeded;
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
}

fn waitForFlowUnsubscribed(preview: *Preview, flow_name: []const u8, deadline_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (preview.isFlowSubscribed(flow_name)) {
        try preview.pollSubscription();
        const now = std.time.milliTimestamp();
        if (now - start > @as(i64, @intCast(deadline_ms))) return error.UnsubscribeDeadlineExceeded;
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
}

test "emitNodeEntered: emits one binary frame when flow is subscribed" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"test_flow\"}");
    try waitForFlowSubscription(&preview, "test_flow", 1000);

    try preview.emitNodeEntered("test_flow", 42);

    var payload_buf: [256]u8 = undefined;
    const frame = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.node_entered), frame.kind);
    // [u16 flow_name_len][flow_name][u32 node_id]
    const name_len = std.mem.readInt(u16, frame.payload[0..2], .little);
    try std.testing.expectEqual(@as(u16, 9), name_len);
    try std.testing.expectEqualStrings("test_flow", frame.payload[2 .. 2 + name_len]);
    const id_off: usize = 2 + name_len;
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, frame.payload[id_off..][0..4], .little));
    // Payload tightly sized — no trailing bytes.
    try std.testing.expectEqual(id_off + 4, frame.payload.len);
}

test "emitNodeEntered: no-op when flow is not subscribed" {
    // Default empty subscription set → opt-in semantics → silence.
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try std.testing.expect(!preview.isFlowSubscribed("test_flow"));
    try preview.emitNodeEntered("test_flow", 1);
    try preview.emitNodeEntered("other_flow", 2);

    // Send a single JSON frame so the harness has something to read
    // after the (silent) emits — proves no binary bytes preceded it.
    try preview.sendHeartbeat(500);
    var buf: [256]u8 = undefined;
    try std.testing.expect((try harness.peekByte()) != binary_magic);
    const f = try harness.readFrame(&buf);
    try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"heartbeat\"") != null);
}

test "emitNodeEntered: stops firing after unsubscribe_flow" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"player_state_machine\"}");
    try waitForFlowSubscription(&preview, "player_state_machine", 1000);
    try preview.emitNodeEntered("player_state_machine", 7);

    // Consume the one expected frame.
    var payload_buf: [256]u8 = undefined;
    const frame = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.node_entered), frame.kind);

    try harness.writeJsonLine("{\"kind\":\"unsubscribe_flow\",\"flow\":\"player_state_machine\"}");
    try waitForFlowUnsubscribed(&preview, "player_state_machine", 1000);

    // After unsubscribe the emit must be a no-op. Probe with a
    // heartbeat so we can prove no binary frame slipped through.
    try preview.emitNodeEntered("player_state_machine", 8);
    try preview.sendHeartbeat(999);
    try std.testing.expect((try harness.peekByte()) != binary_magic);
    var buf: [256]u8 = undefined;
    const f = try harness.readFrame(&buf);
    try std.testing.expect(std.mem.indexOf(u8, f, "\"kind\":\"heartbeat\"") != null);
}

test "emitNodeEntered: exact wire-format guard against drift" {
    // Hand-compose the bytes we expect on the wire for one frame and
    // diff against `emitNodeEntered`'s output byte-for-byte. Guards
    // against accidental layout changes — the editor parses this
    // exact shape.
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"hud\"}");
    try waitForFlowSubscription(&preview, "hud", 1000);

    try preview.emitNodeEntered("hud", 0x01020304);

    // Header: magic(1) + kind(1) + length(4, LE)
    // Payload: u16 name_len LE + "hud" + u32 node_id LE
    // payload_len = 2 + 3 + 4 = 9
    const expected = [_]u8{
        binary_magic,
        @intFromEnum(BinaryFrameKind.node_entered),
        9, 0, 0, 0, // length LE
        3, 0, // name_len LE
        'h', 'u', 'd',
        0x04, 0x03, 0x02, 0x01, // node_id LE
    };
    var actual: [expected.len]u8 = undefined;
    try harness.readExact(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "pollSubscription: subscribe_flow / unsubscribe_flow update subscribed_flows" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"alpha\"}");
    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"beta\"}");
    try waitForFlowSubscription(&preview, "alpha", 1000);
    try waitForFlowSubscription(&preview, "beta", 1000);
    try std.testing.expect(preview.isFlowSubscribed("alpha"));
    try std.testing.expect(preview.isFlowSubscribed("beta"));
    try std.testing.expect(!preview.isFlowSubscribed("gamma"));

    // Speculative subscribe to a flow that doesn't exist yet must
    // silently succeed — editors subscribe before flows load.
    try harness.writeJsonLine("{\"kind\":\"subscribe_flow\",\"flow\":\"not_yet_loaded\"}");
    try waitForFlowSubscription(&preview, "not_yet_loaded", 1000);

    try harness.writeJsonLine("{\"kind\":\"unsubscribe_flow\",\"flow\":\"beta\"}");
    try waitForFlowUnsubscribed(&preview, "beta", 1000);
    try std.testing.expect(preview.isFlowSubscribed("alpha"));
    try std.testing.expect(!preview.isFlowSubscribed("beta"));
    try std.testing.expect(preview.isFlowSubscribed("not_yet_loaded"));
}

// ── Phase 3 / #534 — watch_entity protocol + filtered emission ──────

/// Spin until `preview.pollSubscription` reports the given entity is
/// in the watched set. Bounded so a broken implementation can't hang
/// the test runner.
fn waitForWatchedEntity(preview: *Preview, id: u64, deadline_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        try preview.pollSubscription();
        if (preview.watched_entities.contains(id)) return;
        if (std.time.milliTimestamp() - start > @as(i64, @intCast(deadline_ms))) {
            return error.WatchEntityDeadlineExceeded;
        }
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
}

fn waitForUnwatchedEntity(preview: *Preview, id: u64, deadline_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (preview.watched_entities.contains(id)) {
        try preview.pollSubscription();
        if (std.time.milliTimestamp() - start > @as(i64, @intCast(deadline_ms))) {
            return error.UnwatchEntityDeadlineExceeded;
        }
        { var _req: std.c.timespec = .{ .sec = (1 * std.time.ns_per_ms / std.time.ns_per_s), .nsec = (1 * std.time.ns_per_ms % std.time.ns_per_s) }; var _rem: std.c.timespec = undefined; _ = std.c.nanosleep(&_req, &_rem); }
    }
}

test "watch_entity: adds id to watched_entities and filters subsequent emits" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    // Subscribe to Position so component_changed can actually flow.
    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);

    // Empty watched_entities → "watch everything" mode. Both entities
    // should currently emit.
    try std.testing.expect(preview.isEntityWatched(42));
    try std.testing.expect(preview.isEntityWatched(99));

    // Editor watches entity 42.
    try harness.writeJsonLine("{\"kind\":\"watch_entity\",\"id\":42}");
    try waitForWatchedEntity(&preview, 42, 1000);
    try std.testing.expect(preview.isEntityWatched(42));
    try std.testing.expect(!preview.isEntityWatched(99));

    // Emit on entity 42 — should flow on the wire.
    try preview.emitComponentChanged(42, "Position", &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD });
    // Emit on entity 99 — must NOT flow (watched_entities non-empty,
    // 99 not in the set).
    try preview.emitComponentChanged(99, "Position", &[_]u8{ 0x11, 0x22, 0x33, 0x44 });
    // A second emit on 42 to give us a deterministic "next frame".
    try preview.emitComponentChanged(42, "Position", &[_]u8{ 0xEE, 0xFF });

    // First frame is the first 42 emit.
    var payload_buf: [256]u8 = undefined;
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
    }
    // Second frame must skip 99 entirely and be the second 42 emit.
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        const data_off: usize = 10 + name_len;
        const data_len = std.mem.readInt(u32, f.payload[data_off..][0..4], .little);
        try std.testing.expectEqual(@as(u32, 2), data_len);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEE, 0xFF }, f.payload[data_off + 4 .. data_off + 4 + data_len]);
    }
}

test "unwatch_entity: empty set restores Phase 2 'watch everything' behaviour" {
    // Design decision (#534): when the editor removes the last watched
    // id, `watched_entities` empties and we fall back to "watch
    // everything" — i.e. the Phase 2 default. Rationale: multi-entity
    // tracking is Phase 4+; today's editor watches one entity at a
    // time, and a strict include-list that goes silent the instant the
    // user deselects would surprise callers who rely on the Phase 2
    // contract. The empty-set rule is the single chokepoint
    // (`isEntityWatched`), so flipping the semantics later is a one-
    // line change if Phase 4 wants it.
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);

    try harness.writeJsonLine("{\"kind\":\"watch_entity\",\"id\":42}");
    try waitForWatchedEntity(&preview, 42, 1000);

    // Sanity: while 42 is watched, 99 stays silent.
    try preview.emitComponentChanged(99, "Position", &[_]u8{0xCC});
    try preview.emitComponentChanged(42, "Position", &[_]u8{0xDE});
    var payload_buf: [256]u8 = undefined;
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
    }

    // Editor unwatches 42 → set becomes empty → back to "watch all".
    try harness.writeJsonLine("{\"kind\":\"unwatch_entity\",\"id\":42}");
    try waitForUnwatchedEntity(&preview, 42, 1000);
    try std.testing.expectEqual(@as(usize, 0), preview.watched_entities.count());
    try std.testing.expect(preview.isEntityWatched(42));
    try std.testing.expect(preview.isEntityWatched(99));

    // Both entities now ride the wire again.
    try preview.emitComponentChanged(99, "Position", &[_]u8{0xAA});
    try preview.emitComponentChanged(42, "Position", &[_]u8{0xBB});
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@as(u64, 99), std.mem.readInt(u64, f.payload[0..8], .little));
    }
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
    }
}

test "emitEntitySnapshot: writes one component_changed frame per (entity, component)" {
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\",\"Velocity\"]}");
    try waitForSubscription(&preview, "Position", 1000);
    try waitForSubscription(&preview, "Velocity", 1000);

    const components = [_]preview_mode.SnapshotComponent{
        .{ .name = "Position", .bytes = &[_]u8{ 0x01, 0x02, 0x03, 0x04 } },
        .{ .name = "Velocity", .bytes = &[_]u8{ 0x10, 0x20 } },
    };
    try preview.emitEntitySnapshot(42, &components);

    var payload_buf: [256]u8 = undefined;
    // Frame 1: Position.
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        try std.testing.expectEqualStrings("Position", f.payload[10 .. 10 + name_len]);
        const data_off: usize = 10 + name_len;
        const data_len = std.mem.readInt(u32, f.payload[data_off..][0..4], .little);
        try std.testing.expectEqual(@as(u32, 4), data_len);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, f.payload[data_off + 4 .. data_off + 4 + data_len]);
    }
    // Frame 2: Velocity.
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, f.payload[0..8], .little));
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        try std.testing.expectEqualStrings("Velocity", f.payload[10 .. 10 + name_len]);
        const data_off: usize = 10 + name_len;
        const data_len = std.mem.readInt(u32, f.payload[data_off..][0..4], .little);
        try std.testing.expectEqual(@as(u32, 2), data_len);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x20 }, f.payload[data_off + 4 .. data_off + 4 + data_len]);
    }
}

test "emitEntitySnapshot: skips components the editor did not subscribe to" {
    // Snapshots bypass the entity filter but still honour the
    // component-name filter so we don't leak component kinds the
    // editor never asked for.
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);

    const components = [_]preview_mode.SnapshotComponent{
        .{ .name = "Position", .bytes = &[_]u8{0xAA} },
        .{ .name = "Velocity", .bytes = &[_]u8{0xBB} },
        .{ .name = "Health", .bytes = &[_]u8{0xCC} },
    };
    try preview.emitEntitySnapshot(7, &components);
    // Follow with a sentinel emit on a different entity so we can
    // bound the read — emitEntitySnapshot bypasses watched_entities
    // so a watched-entity flip isn't needed to make this emit fire.
    try preview.emitComponentChanged(8, "Position", &[_]u8{0xFF});

    var payload_buf: [256]u8 = undefined;
    // Only Position should appear from the snapshot.
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
        try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, f.payload[0..8], .little));
        const name_len = std.mem.readInt(u16, f.payload[8..10], .little);
        try std.testing.expectEqualStrings("Position", f.payload[10 .. 10 + name_len]);
    }
    // Then the sentinel — proving Velocity/Health were dropped.
    {
        const f = try harness.readBinaryFrame(&payload_buf);
        try std.testing.expectEqual(@as(u64, 8), std.mem.readInt(u64, f.payload[0..8], .little));
    }
}

test "emitEntitySnapshot: bypasses watched_entities filter for unwatched ids" {
    // The editor has asked to watch entity 42 only, but a snapshot of
    // entity 99 must still go out — by the time the caller invokes
    // emitEntitySnapshot it has already decided that entity is
    // interesting (typically because the editor just sent
    // watch_entity for it; the in-engine wiring lands in a follow-up).
    const allocator = std.testing.allocator;
    var harness = try LoopbackHarness.init();
    defer harness.deinit();

    var host_port_buf: [32]u8 = undefined;
    const host_port = try harness.hostPort(&host_port_buf);
    var preview = try Preview.connect(allocator, host_port);
    defer preview.deinit();
    try harness.accept();

    try harness.writeJsonLine("{\"kind\":\"subscribe\",\"components\":[\"Position\"]}");
    try waitForSubscription(&preview, "Position", 1000);

    try harness.writeJsonLine("{\"kind\":\"watch_entity\",\"id\":42}");
    try waitForWatchedEntity(&preview, 42, 1000);

    const components = [_]preview_mode.SnapshotComponent{
        .{ .name = "Position", .bytes = &[_]u8{0x55} },
    };
    try preview.emitEntitySnapshot(99, &components);

    var payload_buf: [256]u8 = undefined;
    const f = try harness.readBinaryFrame(&payload_buf);
    try std.testing.expectEqual(@intFromEnum(BinaryFrameKind.component_changed), f.kind);
    try std.testing.expectEqual(@as(u64, 99), std.mem.readInt(u64, f.payload[0..8], .little));
}

test "Game without preview attached: ECS lifecycle is a no-op for telemetry (#520)" {
    // Sanity check that the `if (self.preview) |*p|` guards genuinely
    // short-circuit — a Game with `preview = null` must not crash, write
    // to any socket, or otherwise misbehave on the lifecycle paths.
    const allocator = std.testing.allocator;
    var game = Game.init(allocator);
    defer game.deinit();

    try std.testing.expect(game.preview == null);

    const e = game.createEntity();
    game.addComponent(e, TestPos{ .x = 1, .y = 2 });
    game.setComponent(e, TestPos{ .x = 3, .y = 4 });
    game.destroyEntity(e);

    try std.testing.expectEqual(@as(usize, 0), game.entityCount());
}
