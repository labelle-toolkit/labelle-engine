/// Preview mode — connect-out control channel for the labelle-gui editor.
///
/// Phase 0 spike for the Play-in-Editor preview umbrella
/// (labelle-gui#59). Architecture decision is in labelle-gui#60 and the
/// engine-side issue is labelle-engine#516.
///
/// ## Model
///
/// The editor binds a loopback TCP listener and passes the host:port
/// down to the engine on the CLI (`--preview-mode 127.0.0.1:54321`).
/// The engine *dials out* into the editor — this avoids the engine
/// needing to publish a port and lets the editor own port selection,
/// matches the way the editor already spawns child processes for
/// build/run (see labelle-gui/src/compiler.zig), and keeps the
/// connection ephemeral: when the editor goes away, the socket EOFs
/// and the engine notices.
///
/// ## Protocol
///
/// Newline-delimited JSON. One frame per message. The Phase 0 subset
/// is three messages, all engine → editor:
///
///     {"kind":"hello","engine_version":"…","pid":12345,"protocol_version":1}\n
///     {"kind":"heartbeat","t":847291}\n
///     {"kind":"bye","reason":"normal"}\n
///
/// `bye.reason` is one of `normal`, `crashed`, `killed`. Only `normal`
/// is emitted by the spike — the other two are reserved for future
/// shutdown paths. Editor reads EOF as "engine died abnormally".
///
/// Phase 2 will replace newline framing with a length-prefixed binary
/// channel once telemetry shows up (entity state, flow events). Until
/// then JSON keeps the wire human-readable for spike debugging.
///
/// ## Lifecycle
///
/// 1. Generated `main.zig` parses `--preview-mode <host:port>` from
///    its own argv (the engine has no `main()` of its own — see the
///    "Where the flag lives" note in `CLAUDE.md`).
/// 2. `Preview.connect(host_port)` dials the editor; failure is
///    surfaced to the caller, which decides whether to exit the
///    process or fall back to non-preview run.
/// 3. `sendHello` fires immediately. The engine loop calls
///    `sendHeartbeat` roughly every 250 ms (rate-limited internally
///    so the call site can be a per-tick poll without flooding).
/// 4. On clean shutdown `sendBye(.normal)` + `deinit` close the
///    socket. On abnormal exit the OS closes the FD and the editor
///    infers the crash from the EOF without a `bye`.
const std = @import("std");
const builtin = @import("builtin");

/// Reason emitted in the trailing `bye` frame. Spike only ever sends
/// `.normal`; `.crashed` / `.killed` are reserved for richer shutdown
/// reporting once the runner / signal handlers learn about preview.
pub const ByeReason = enum {
    normal,
    crashed,
    killed,

    pub fn asString(self: ByeReason) []const u8 {
        return switch (self) {
            .normal => "normal",
            .crashed => "crashed",
            .killed => "killed",
        };
    }
};

/// Wire-format protocol version. Editor compares against this in the
/// `hello` frame. Bump every time the message shapes change in an
/// incompatible way.
pub const protocol_version: u32 = 1;

/// Default heartbeat interval. The game loop is welcome to poll
/// `Preview.tickHeartbeat` every frame — the rate-limit keeps the
/// wire traffic at ~4 Hz regardless of frame rate.
pub const heartbeat_interval_ms: u64 = 250;

pub const ParseError = error{
    InvalidAddress,
    InvalidPort,
};

pub const ConnectError = std.net.TcpConnectToAddressError || ParseError;

pub const WriteError = std.net.Stream.WriteError || error{OutOfMemory};

/// The connect-out control channel. Owned by the game; one per
/// process. Cheap to construct — single arena + one TCP fd.
pub const Preview = struct {
    stream: std.net.Stream,
    arena: std.heap.ArenaAllocator,
    last_heartbeat_ms: u64 = 0,

    /// Dial the editor's listener. `host_port` is the literal string
    /// pulled from `--preview-mode <host:port>` — `127.0.0.1:54321`
    /// or `[::1]:54321`. The arena's parent allocator is used for
    /// the small JSON scratch space; pick any general-purpose
    /// allocator (typically `game.allocator`).
    pub fn connect(parent_alloc: std.mem.Allocator, host_port: []const u8) ConnectError!Preview {
        const addr = std.net.Address.parseIpAndPort(host_port) catch |err| switch (err) {
            error.InvalidAddress => return error.InvalidAddress,
            error.InvalidPort => return error.InvalidPort,
        };
        const stream = try std.net.tcpConnectToAddress(addr);
        return .{
            .stream = stream,
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
        };
    }

    pub fn deinit(self: *Preview) void {
        // Closing the socket is idempotent — `sendBye` does NOT close
        // so the caller can still observe write failures; we always
        // close here.
        self.stream.close();
        self.arena.deinit();
    }

    /// Send the initial `hello` frame. Call exactly once, immediately
    /// after `connect`.
    pub fn sendHello(self: *Preview, engine_version: []const u8, pid: i32) WriteError!void {
        const Msg = struct {
            kind: []const u8 = "hello",
            engine_version: []const u8,
            pid: i32,
            protocol_version: u32,
        };
        try self.writeFrame(Msg{
            .engine_version = engine_version,
            .pid = pid,
            .protocol_version = protocol_version,
        });
    }

    /// Send a `heartbeat` frame with the given monotonic millisecond
    /// timestamp. Use `tickHeartbeat` instead if you want the
    /// rate-limit handled for you.
    pub fn sendHeartbeat(self: *Preview, t_ms: u64) WriteError!void {
        const Msg = struct {
            kind: []const u8 = "heartbeat",
            t: u64,
        };
        try self.writeFrame(Msg{ .t = t_ms });
        self.last_heartbeat_ms = t_ms;
    }

    /// Frame-friendly heartbeat: only emits if at least
    /// `heartbeat_interval_ms` have elapsed since the last one.
    /// `now_ms` should be a monotonic millisecond reading
    /// (`std.time.milliTimestamp()` is fine — wall-clock skew is
    /// irrelevant at this granularity for the spike).
    pub fn tickHeartbeat(self: *Preview, now_ms: u64) WriteError!void {
        if (self.last_heartbeat_ms == 0 or now_ms -% self.last_heartbeat_ms >= heartbeat_interval_ms) {
            try self.sendHeartbeat(now_ms);
        }
    }

    /// Send the final `bye` frame. Best-effort: failure to write is
    /// reported but the caller is expected to continue tearing down
    /// (the editor sees EOF either way).
    pub fn sendBye(self: *Preview, reason: ByeReason) WriteError!void {
        const Msg = struct {
            kind: []const u8 = "bye",
            reason: []const u8,
        };
        try self.writeFrame(Msg{ .reason = reason.asString() });
    }

    fn writeFrame(self: *Preview, msg: anytype) WriteError!void {
        // Use the arena as scratch; reset after every frame so the
        // arena footprint stays at one message worth of memory.
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const body = try std.json.Stringify.valueAlloc(alloc, msg, .{});
        // Newline framing: one JSON document per `\n`-terminated
        // chunk. Build the framed payload in the arena so we hit
        // the wire with a single `writeAll` (the editor reads with
        // its own buffered reader; we don't want a torn frame from
        // a partial write here).
        const framed = try alloc.alloc(u8, body.len + 1);
        @memcpy(framed[0..body.len], body);
        framed[body.len] = '\n';
        try self.stream.writeAll(framed);
    }
};

/// Pull `--preview-mode <host:port>` out of an argv slice and return
/// the host:port string (a slice into the same argv, so the caller
/// owns the lifetime). Returns `null` if the flag is absent.
///
/// Accepts both space-separated (`--preview-mode 127.0.0.1:54321`)
/// and equals-form (`--preview-mode=127.0.0.1:54321`).
///
/// The engine is a library, so this helper exists for the
/// assembler-generated `main.zig` to call. See `CLAUDE.md` "Where the
/// flag lives".
pub fn parseArgs(argv: []const []const u8) ?[]const u8 {
    const flag = "--preview-mode";
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, flag)) {
            if (i + 1 >= argv.len) return null;
            return argv[i + 1];
        }
        if (std.mem.startsWith(u8, a, flag ++ "=")) {
            return a[flag.len + 1 ..];
        }
    }
    return null;
}

// Tests live in `test/preview_mode_test.zig` — that's where the
// engine wires test binaries (per build.zig). Keeping the
// implementation file test-free matches the established pattern
// (game_log.zig + test/game_log_test.zig, sparse_set.zig +
// test/sparse_set_test.zig, etc.).

// Silence the `builtin` unused-import warning in release builds —
// kept available because Phase 1 wiring (signal handlers for
// `bye{reason:killed}`) will fork on os tag.
comptime {
    _ = builtin;
}
