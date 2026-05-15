/// Preview mode — connect-out control channel for the labelle-gui editor.
///
/// Phase 0 spike for the Play-in-Editor preview umbrella
/// (labelle-gui#59). Architecture decision is in labelle-gui#60 and the
/// engine-side issue is labelle-engine#516. Phase 2 (labelle-engine#518)
/// extends the JSON control plane with a binary state-telemetry channel
/// multiplexed on the same TCP socket.
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
/// Two interleaved framings share the same TCP socket:
///
/// 1. **JSON control plane** (Phase 1) — newline-delimited JSON. One
///    document per `\n`-terminated chunk. JSON documents always start
///    with `{`, never `0x1B`, so the reader can disambiguate by
///    peeking the first byte.
///
///        {"kind":"hello","engine_version":"…","pid":12345,"protocol_version":1}\n
///        {"kind":"heartbeat","t":847291}\n
///        {"kind":"bye","reason":"normal"}\n
///        {"kind":"subscribe","components":["Position","Velocity"]}\n   (editor → engine)
///        {"kind":"unsubscribe","components":["Velocity"]}\n             (editor → engine)
///        {"kind":"watch_entity","id":42}\n                               (editor → engine, Phase 3)
///        {"kind":"unwatch_entity","id":42}\n                             (editor → engine, Phase 3)
///
/// 2. **Binary telemetry plane** (Phase 2) — length-prefixed records
///    led by an `ESC` (0x1B) magic byte:
///
///        [u8 magic=0x1B] [u8 kind] [u32 length, little-endian] [payload]
///
///    `kind` is `BinaryFrameKind`; `length` is the byte count of
///    `payload` only (does not include the 6-byte header). Strings
///    inside payloads use a `[u16 length-LE] [bytes]` shape. The
///    editor reads the first byte: if it's `0x1B` it decodes a binary
///    frame; otherwise it accumulates until `\n` and parses JSON.
///
/// `bye.reason` is one of `normal`, `crashed`, `killed`. Only `normal`
/// is emitted by the spike — the other two are reserved for future
/// shutdown paths. Editor reads EOF as "engine died abnormally".
///
/// ## TODO (Phase 2 polish)
///
/// - **Per-tick batching**: today every `emitComponentChanged` issues
///   its own `writeAll`. For a real game with thousands of touches per
///   tick we'll want to buffer into a per-frame digest and flush once
///   at end-of-tick (see #518's "Throttling" section). The shape would
///   be a single `component_digest` frame containing N tuples — wire-
///   compatible with the current `component_changed` decoder by being
///   a separate kind.
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

// Raw libc bindings: std.posix in 0.16 dropped top-level `close` and
// `write` wrappers and routed file IO through `std.Io.File` which
// needs an `io: std.Io` reference we'd otherwise have to thread
// through every call site. The control channel is POSIX-only by
// design (the fcntl-based non-blocking poll already had no Windows
// path), so going straight to libc is the smallest restoration.
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern "c" fn __error() *c_int; // macOS errno location
extern "c" fn __errno_location() *c_int; // glibc errno location

fn libcErrno() c_int {
    return if (@import("builtin").os.tag == .macos) __error().* else __errno_location().*;
}

// POSIX constants we need for the non-blocking-poll path. Match
// the Linux/macOS values that libc's <fcntl.h> ships.
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = if (@import("builtin").os.tag == .macos) 4 else 2048;
const EAGAIN: c_int = if (@import("builtin").os.tag == .macos) 35 else 11;
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

/// Magic byte that flags a binary telemetry frame on the multiplexed
/// socket. Chosen as `ESC` (0x1B) because no valid JSON document or
/// whitespace prefix can begin with it — the editor's reader peeks
/// the first byte to discriminate.
pub const binary_magic: u8 = 0x1B;

/// Kinds of binary frames emitted by the engine. Numbered explicitly
/// because these go on the wire — appending is safe, reordering is a
/// protocol break.
pub const BinaryFrameKind = enum(u8) {
    entity_created = 1,
    entity_destroyed = 2,
    component_changed = 3,
    node_entered = 4,
    pin_value = 5,
    _,
};

/// Default heartbeat interval. The game loop is welcome to poll
/// `Preview.tickHeartbeat` every frame — the rate-limit keeps the
/// wire traffic at ~4 Hz regardless of frame rate.
pub const heartbeat_interval_ms: u64 = 250;

/// A (component_name, raw_bytes) pair for `emitEntitySnapshot`. Both
/// slices are borrowed — they only need to outlive the snapshot call.
pub const SnapshotComponent = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const ParseError = error{
    InvalidAddress,
    InvalidPort,
};

pub const ConnectError = std.Io.net.IpAddress.ConnectError || ParseError || error{ConnectFailed};

pub const WriteError = error{ BrokenPipe, WriteFailed, OutOfMemory };

/// Errors that `pollSubscription` can surface. Read errors propagate;
/// JSON shape errors fold into a single `MalformedSubscription` so the
/// caller can decide whether to log-and-continue or tear down.
pub const PollError = std.posix.ReadError || error{
    OutOfMemory,
    MalformedSubscription,
};

/// The connect-out control channel. Owned by the game; one per
/// process. Cheap to construct — single arena + one TCP fd.
///
/// Holds two pieces of long-lived state past Phase 1:
///
/// - `subscribed_components` — names the editor has asked to receive
///   `component_changed` frames for. Default empty: until the editor
///   opts in, no component traffic flows. Lifecycle frames
///   (`entity_created`/`entity_destroyed`) always emit.
/// - `watched_entities` — entity IDs the editor has asked to scope
///   `component_changed` frames to (Phase 3 / #534). Empty set means
///   "watch everything" (Phase 2 back-compat). Non-empty set means
///   only IDs in the set emit; the component-name filter still
///   applies on top.
/// - `inbox` — partial-read buffer for the editor → engine direction
///   (newline-delimited JSON: `subscribe`/`unsubscribe`/
///   `watch_entity`/`unwatch_entity`). Sized for a handful of names;
///   grows on demand via `inbox_alloc`.
pub const Preview = struct {
    /// Raw socket fd. We bypass `std.Io.net.Stream`'s typed reader/
    /// writer and go straight to POSIX `read` / `write` / `close` —
    /// the only platform that needs the polling path uses POSIX
    /// `fcntl` anyway (see `pollSubscription`), and bypassing the
    /// `Io.Reader`/`Writer` interface saves us from threading
    /// `io: std.Io` through every call site.
    fd: std.posix.fd_t,
    arena: std.heap.ArenaAllocator,
    last_heartbeat_ms: u64 = 0,
    /// Set of component names the editor wants `component_changed`
    /// frames for. Keys allocated in `subs_arena` so the editor can
    /// churn the set without leaking into the per-frame `arena`.
    subscribed_components: std.StringHashMapUnmanaged(void) = .empty,
    /// Set of flow names (the `.flow.zon` file stem, no path / no
    /// extension) the editor wants `node_entered` frames for. Inverse
    /// default vs. `subscribed_components`: empty set means **no**
    /// emit. Flow nodes fire much more frequently than component
    /// changes (60+ Hz across many flows), so opt-in is the safer
    /// default — editors that don't care pay zero cost.
    subscribed_flows: std.StringHashMapUnmanaged(void) = .empty,
    /// Set of flow names the editor wants `pin_value` frames for.
    /// Mirror of `subscribed_flows` but tracks the (potentially much
    /// higher-volume) live pin/edge value channel separately so the
    /// editor can opt into node pulses without paying for per-pin
    /// payloads (or vice versa). Empty set means **no** emit — same
    /// opt-in semantics as `subscribed_flows`.
    subscribed_pin_flows: std.StringHashMapUnmanaged(void) = .empty,
    subs_arena: std.heap.ArenaAllocator,
    /// Set of entity IDs the editor wants `component_changed` frames
    /// scoped to. See the field-level doc on `Preview` for the
    /// empty-set semantics (= "watch everything").
    watched_entities: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Inbound newline-framing buffer for `pollSubscription`. Owned
    /// by `inbox_alloc` (the parent allocator) so it can grow past the
    /// initial capacity if a very long subscribe list arrives.
    inbox: std.ArrayListUnmanaged(u8) = .empty,
    inbox_alloc: std.mem.Allocator,

    /// Dial the editor's listener. `host_port` is the literal string
    /// pulled from `--preview-mode <host:port>` — `127.0.0.1:54321`
    /// or `[::1]:54321`. The arena's parent allocator is used for
    /// the small JSON scratch space; pick any general-purpose
    /// allocator (typically `game.allocator`).
    pub fn connect(io: std.Io, parent_alloc: std.mem.Allocator, host_port: []const u8) ConnectError!Preview {
        const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidAddress;
        const host_text = host_port[0..colon];
        const port_text = host_port[colon + 1 ..];
        // Strip brackets from IPv6 literals (`[::1]:port`).
        const host_clean = if (host_text.len >= 2 and host_text[0] == '[' and host_text[host_text.len - 1] == ']')
            host_text[1 .. host_text.len - 1]
        else
            host_text;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
        const addr = std.Io.net.IpAddress.parse(host_clean, port) catch return error.InvalidAddress;
        const stream = addr.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;
        return .{
            .fd = stream.socket.handle,
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .subs_arena = std.heap.ArenaAllocator.init(parent_alloc),
            .inbox_alloc = parent_alloc,
        };
    }

    pub fn deinit(self: *Preview) void {
        // Closing the socket is idempotent — `sendBye` does NOT close
        // so the caller can still observe write failures; we always
        // close here.
        _ = close(self.fd);
        self.subscribed_components.deinit(self.subs_arena.allocator());
        self.subscribed_flows.deinit(self.subs_arena.allocator());
        self.subscribed_pin_flows.deinit(self.subs_arena.allocator());
        self.watched_entities.deinit(self.subs_arena.allocator());
        self.subs_arena.deinit();
        self.inbox.deinit(self.inbox_alloc);
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

    // ── Binary telemetry frames (Phase 2 / #518) ────────────────────

    /// Emit an `entity_created` binary frame.
    ///
    /// Payload layout (little-endian):
    ///
    ///     [u64 entity_id] [u16 name_len] [name_len bytes prefab_name]
    ///
    /// `prefab_name == null` is encoded as `name_len = 0`. Always
    /// emits regardless of subscription state — lifecycle events are
    /// cheap and the editor always wants them.
    pub fn emitEntityCreated(
        self: *Preview,
        entity_id: u64,
        prefab_name: ?[]const u8,
    ) WriteError!void {
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const name = prefab_name orelse "";
        const payload_len: usize = @sizeOf(u64) + @sizeOf(u16) + name.len;
        const buf = try alloc.alloc(u8, payload_len);
        std.mem.writeInt(u64, buf[0..8], entity_id, .little);
        std.mem.writeInt(u16, buf[8..10], @intCast(name.len), .little);
        @memcpy(buf[10 .. 10 + name.len], name);
        try self.writeBinaryFrame(.entity_created, buf);
    }

    /// Emit an `entity_destroyed` binary frame.
    ///
    /// Payload layout: `[u64 entity_id]`. Always emits.
    pub fn emitEntityDestroyed(self: *Preview, entity_id: u64) WriteError!void {
        var buf: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &buf, entity_id, .little);
        try self.writeBinaryFrame(.entity_destroyed, &buf);
    }

    /// Emit a `component_changed` binary frame. **No-op when the
    /// component name is not in `subscribed_components`** — this is
    /// the hot path, so the early-out keeps the engine from doing
    /// even a single allocation if the editor hasn't asked for this
    /// component yet.
    ///
    /// Phase 3 (#534): also no-op when `watched_entities` is non-
    /// empty AND `entity_id` is not in the set. Empty `watched_entities`
    /// preserves Phase 2 "watch everything" semantics so existing
    /// callers see no behaviour change until the editor opts in.
    ///
    /// Payload layout (little-endian):
    ///
    ///     [u64 entity_id] [u16 name_len] [name bytes] [u32 data_len] [data bytes]
    ///
    /// `comp_bytes` is opaque to the engine — the editor decides how
    /// to interpret it based on `comp_name`. The current expectation
    /// is the same byte layout the serializer plugin already writes.
    pub fn emitComponentChanged(
        self: *Preview,
        entity_id: u64,
        comp_name: []const u8,
        comp_bytes: []const u8,
    ) WriteError!void {
        if (!self.isComponentSubscribed(comp_name)) return;
        if (!self.isEntityWatched(entity_id)) return;
        try self.writeComponentChangedFrame(entity_id, comp_name, comp_bytes);
    }

    /// Emit a one-shot "snapshot" of an entity's components. Mechanically
    /// just N back-to-back `component_changed` frames — the snapshot is
    /// the wire-level concept of "all current values right now" rather
    /// than a distinct frame kind. Useful right after the editor sends
    /// `watch_entity` so the UI doesn't sit on a stale view until the
    /// next mutation.
    ///
    /// Bypasses the `watched_entities` filter (the caller has obviously
    /// already decided this entity is interesting) but **honours**
    /// `subscribed_components` so a snapshot doesn't leak component
    /// kinds the editor hasn't opted into.
    ///
    /// Note: `Preview` does not own the ECS, so it can't walk an entity's
    /// components on its own — `game.zig` knows that mapping and is
    /// expected to call this helper from its `watch_entity` arrival
    /// hook. As of Phase 3 the wiring on the `game.zig` side is still a
    /// follow-up; this method exposes the wire format so that follow-up
    /// has a single call site.
    pub fn emitEntitySnapshot(
        self: *Preview,
        entity_id: u64,
        components: []const SnapshotComponent,
    ) WriteError!void {
        for (components) |c| {
            if (!self.isComponentSubscribed(c.name)) continue;
            try self.writeComponentChangedFrame(entity_id, c.name, c.bytes);
        }
    }

    fn writeComponentChangedFrame(
        self: *Preview,
        entity_id: u64,
        comp_name: []const u8,
        comp_bytes: []const u8,
    ) WriteError!void {
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const payload_len: usize = @sizeOf(u64) + @sizeOf(u16) + comp_name.len + @sizeOf(u32) + comp_bytes.len;
        const buf = try alloc.alloc(u8, payload_len);
        var off: usize = 0;
        std.mem.writeInt(u64, buf[off..][0..8], entity_id, .little);
        off += 8;
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(comp_name.len), .little);
        off += 2;
        @memcpy(buf[off .. off + comp_name.len], comp_name);
        off += comp_name.len;
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(comp_bytes.len), .little);
        off += 4;
        @memcpy(buf[off .. off + comp_bytes.len], comp_bytes);
        try self.writeBinaryFrame(.component_changed, buf);
    }

    /// Emit a `node_entered` binary frame. **No-op when the flow
    /// name is not in `subscribed_flows`** — flow nodes fire at
    /// frame rate across many flows, so the early-out keeps the
    /// engine from doing even a single allocation if the editor
    /// hasn't asked for this flow yet.
    ///
    /// Payload layout (little-endian):
    ///
    ///     [u16 flow_name_len] [flow_name bytes (UTF-8)] [u32 node_id]
    ///
    /// `flow_name` is the `.flow.zon` file stem (no path, no
    /// extension); `node_id` is the stable u32 id the flow_io parser
    /// assigns to each node.
    pub fn emitNodeEntered(
        self: *Preview,
        flow_name: []const u8,
        node_id: u32,
    ) WriteError!void {
        if (!self.isFlowSubscribed(flow_name)) return;
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const payload_len: usize = @sizeOf(u16) + flow_name.len + @sizeOf(u32);
        const buf = try alloc.alloc(u8, payload_len);
        var off: usize = 0;
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(flow_name.len), .little);
        off += 2;
        @memcpy(buf[off .. off + flow_name.len], flow_name);
        off += flow_name.len;
        std.mem.writeInt(u32, buf[off..][0..4], node_id, .little);
        try self.writeBinaryFrame(.node_entered, buf);
    }

    /// Emit a `pin_value` binary frame. **No-op when the flow name is
    /// not in `subscribed_pin_flows`** — pin values fire on every
    /// edge evaluation (potentially many per node per frame), so the
    /// early-out keeps the engine from doing even a single allocation
    /// if the editor hasn't asked for this flow's pin stream yet.
    ///
    /// Tracked as a separate subscription set from `subscribed_flows`
    /// (the `node_entered` opt-in) on purpose: the editor will
    /// typically subscribe to both when a flow tab is opened, but the
    /// pin channel is by far the higher-volume one and a future
    /// editor (e.g. minimap) may want node pulses without paying for
    /// pin payloads. Keeping the sets independent preserves symmetry
    /// with `node_entered`'s `subscribe_flow` and avoids a flag-bit
    /// hack inside one control message.
    ///
    /// Payload layout (little-endian):
    ///
    ///     [u16 flow_name_len] [flow_name bytes (UTF-8)]
    ///     [u32 node_id]
    ///     [u16 pin_name_len] [pin_name bytes (UTF-8)]
    ///     [f64 value]
    ///
    /// `flow_name` is the `.flow.zon` file stem (no path, no
    /// extension); `node_id` is the stable u32 id the flow_io parser
    /// assigns to each node; `pin_name` is the pin label exactly as
    /// it appears in the node definition (UTF-8, may contain quotes,
    /// punctuation, non-ASCII).
    ///
    /// **v1 value is `f64`-only.** Covers BinOp results, Literal
    /// numerics, and `dt`. String / bool / struct payloads are
    /// deferred — see the follow-up listed in this PR's body.
    pub fn emitPinValue(
        self: *Preview,
        flow_name: []const u8,
        node_id: u32,
        pin_name: []const u8,
        value: f64,
    ) WriteError!void {
        if (!self.isPinFlowSubscribed(flow_name)) return;
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const payload_len: usize =
            @sizeOf(u16) + flow_name.len +
            @sizeOf(u32) +
            @sizeOf(u16) + pin_name.len +
            @sizeOf(f64);
        const buf = try alloc.alloc(u8, payload_len);
        var off: usize = 0;
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(flow_name.len), .little);
        off += 2;
        @memcpy(buf[off .. off + flow_name.len], flow_name);
        off += flow_name.len;
        std.mem.writeInt(u32, buf[off..][0..4], node_id, .little);
        off += 4;
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(pin_name.len), .little);
        off += 2;
        @memcpy(buf[off .. off + pin_name.len], pin_name);
        off += pin_name.len;
        // f64 bit-pattern as u64, little-endian. Avoids any FP-aware
        // codec — the editor reverses the bitcast on receive.
        const bits: u64 = @bitCast(value);
        std.mem.writeInt(u64, buf[off..][0..8], bits, .little);
        try self.writeBinaryFrame(.pin_value, buf);
    }

    /// Drain any pending `subscribe` / `unsubscribe` / `subscribe_flow`
    /// / `unsubscribe_flow` / `subscribe_pin_values` /
    /// `unsubscribe_pin_values` JSON frames sent by the editor and
    /// apply them to `subscribed_components` / `subscribed_flows` /
    /// `subscribed_pin_flows`. Non-blocking — reads only what's
    /// currently available on the socket. Safe to call once per tick.
    ///
    /// Wire shapes:
    ///
    ///     {"kind":"subscribe","components":["Position","Velocity"]}\n
    ///     {"kind":"unsubscribe","components":["Velocity"]}\n
    ///     {"kind":"subscribe_flow","flow":"player_state_machine"}\n
    ///     {"kind":"unsubscribe_flow","flow":"player_state_machine"}\n
    ///     {"kind":"subscribe_pin_values","flow":"player_state_machine"}\n
    ///     {"kind":"unsubscribe_pin_values","flow":"player_state_machine"}\n
    ///
    /// Returns `MalformedSubscription` if a frame parses as JSON but
    /// the shape doesn't match; the caller can choose to log + drop.
    pub fn pollSubscription(self: *Preview) PollError!void {
        // Pull whatever bytes are currently available on the socket
        // into `inbox` without blocking. We poll only — never wait —
        // so the game loop isn't stalled by an idle editor.
        try self.fillInboxNonBlocking();

        while (true) {
            const nl_idx = std.mem.indexOfScalar(u8, self.inbox.items, '\n') orelse break;
            const line = self.inbox.items[0..nl_idx];
            try self.applySubscriptionFrame(line);
            // Drop the consumed line (including the `\n`).
            const remaining = self.inbox.items.len - (nl_idx + 1);
            std.mem.copyForwards(u8, self.inbox.items[0..remaining], self.inbox.items[nl_idx + 1 ..]);
            self.inbox.shrinkRetainingCapacity(remaining);
        }
    }

    /// Returns `true` if `emitComponentChanged` would emit a frame
    /// for this component. Useful as a guard around the cost of
    /// serializing the component bytes.
    pub fn isComponentSubscribed(self: *const Preview, comp_name: []const u8) bool {
        return self.subscribed_components.contains(comp_name);
    }

    /// Returns `true` if `emitNodeEntered` would emit a frame for
    /// this flow. Useful as a guard around the cost of resolving the
    /// flow name string at the call site.
    pub fn isFlowSubscribed(self: *const Preview, flow_name: []const u8) bool {
        return self.subscribed_flows.contains(flow_name);
    }

    /// Returns `true` if `emitPinValue` would emit a frame for this
    /// flow's pin stream. Useful as a guard around the cost of
    /// computing the value (e.g. resolving a wire's source pin) at
    /// the call site.
    pub fn isPinFlowSubscribed(self: *const Preview, flow_name: []const u8) bool {
        return self.subscribed_pin_flows.contains(flow_name);
    }

    /// Phase 3 (#534) entity-scope check. Returns `true` when the
    /// caller should emit for `entity_id`. The "empty set means watch
    /// everything" rule lives here so call sites stay free of policy.
    pub fn isEntityWatched(self: *const Preview, entity_id: u64) bool {
        if (self.watched_entities.count() == 0) return true;
        return self.watched_entities.contains(entity_id);
    }

    // ── Internals ───────────────────────────────────────────────────

    fn writeBinaryFrame(
        self: *Preview,
        kind: BinaryFrameKind,
        payload: []const u8,
    ) WriteError!void {
        // Build the header + payload in one buffer so we hit the wire
        // with a single `writeAll` — torn frames here would force the
        // editor to deal with mid-record short reads.
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const total = 1 + 1 + 4 + payload.len;
        const framed = try alloc.alloc(u8, total);
        framed[0] = binary_magic;
        framed[1] = @intFromEnum(kind);
        std.mem.writeInt(u32, framed[2..6], @intCast(payload.len), .little);
        @memcpy(framed[6..total], payload);
        var off: usize = 0;
        while (off < framed.len) {
            const n = write(self.fd, framed.ptr + off, framed.len - off);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.BrokenPipe;
            off += @intCast(n);
        }
    }

    fn fillInboxNonBlocking(self: *Preview) PollError!void {
        // POSIX-only fast path via libc directly. Zig 0.16's
        // `std.posix.fcntl` is gone; we already bypass `std.posix.read`
        // / `close` / `write` to avoid `io: std.Io` threading, so the
        // non-blocking poll uses the same libc shim. Set non-blocking,
        // read until EAGAIN, restore flags. The socket stays blocking
        // for writes so partial sends aren't a concern.
        const fd = self.fd;
        const orig_flags = fcntl(fd, F_GETFL, 0);        if (orig_flags < 0) return;
        const set_rc = fcntl(fd, F_SETFL, orig_flags | O_NONBLOCK);        if (set_rc < 0) return;
        defer _ = fcntl(fd, F_SETFL, orig_flags);

        var scratch: [1024]u8 = undefined;
        while (true) {
            const n = read(fd, @ptrCast(&scratch[0]), scratch.len);            if (n < 0) {
                if (libcErrno() == EAGAIN) return;
                return error.InputOutput;
            }
            if (n == 0) return; // EOF — caller infers from subsequent write failures.
            try self.inbox.appendSlice(self.inbox_alloc, scratch[0..@intCast(n)]);        }
    }

    fn applySubscriptionFrame(self: *Preview, line: []const u8) error{ OutOfMemory, MalformedSubscription }!void {
        // The arena is per-frame scratch — fine for transient JSON
        // parsing. Subscription names that survive get copied into
        // `subs_arena` so they outlive the next emit.
        defer _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();

        // Peek the kind first so we can dispatch to a shape-specific
        // parser. `subscribe`/`unsubscribe` carry a `components`
        // array; `subscribe_flow`/`unsubscribe_flow` carry a single
        // `flow` string; `watch_entity`/`unwatch_entity` carry an
        // `id`. Parsing each against its own shape keeps the wire
        // forwards-compatible — future kinds just add a branch here.
        const KindOnly = struct { kind: []const u8 };
        const kind_only = std.json.parseFromSliceLeaky(KindOnly, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedSubscription;

        if (std.mem.eql(u8, kind_only.kind, "subscribe")) {
            const Parsed = struct { kind: []const u8, components: []const []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            const subs_alloc = self.subs_arena.allocator();
            for (parsed.components) |name| {
                if (self.subscribed_components.contains(name)) continue;
                const owned = try subs_alloc.dupe(u8, name);
                try self.subscribed_components.put(subs_alloc, owned, {});
            }
        } else if (std.mem.eql(u8, kind_only.kind, "unsubscribe")) {
            const Parsed = struct { kind: []const u8, components: []const []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            for (parsed.components) |name| {
                _ = self.subscribed_components.remove(name);
            }
        } else if (std.mem.eql(u8, kind_only.kind, "subscribe_flow")) {
            const Parsed = struct { kind: []const u8, flow: []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            if (!self.subscribed_flows.contains(parsed.flow)) {
                const subs_alloc = self.subs_arena.allocator();
                const owned = try subs_alloc.dupe(u8, parsed.flow);
                try self.subscribed_flows.put(subs_alloc, owned, {});
            }
        } else if (std.mem.eql(u8, kind_only.kind, "unsubscribe_flow")) {
            const Parsed = struct { kind: []const u8, flow: []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            _ = self.subscribed_flows.remove(parsed.flow);
        } else if (std.mem.eql(u8, kind_only.kind, "subscribe_pin_values")) {
            const Parsed = struct { kind: []const u8, flow: []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            if (!self.subscribed_pin_flows.contains(parsed.flow)) {
                const subs_alloc = self.subs_arena.allocator();
                const owned = try subs_alloc.dupe(u8, parsed.flow);
                try self.subscribed_pin_flows.put(subs_alloc, owned, {});
            }
        } else if (std.mem.eql(u8, kind_only.kind, "unsubscribe_pin_values")) {
            const Parsed = struct { kind: []const u8, flow: []const u8 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            _ = self.subscribed_pin_flows.remove(parsed.flow);
        } else if (std.mem.eql(u8, kind_only.kind, "watch_entity")) {
            // Phase 3 (#534). Empty `watched_entities` means
            // "watch everything"; once the editor adds an ID we
            // switch to the strict include-list. The follow-up
            // snapshot fire is left to the caller in this PR — the
            // engine doesn't own the ECS, so it can't walk an
            // entity's components from here. See `emitEntitySnapshot`.
            const Parsed = struct { kind: []const u8, id: u64 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            try self.watched_entities.put(self.subs_arena.allocator(), parsed.id, {});
        } else if (std.mem.eql(u8, kind_only.kind, "unwatch_entity")) {
            const Parsed = struct { kind: []const u8, id: u64 };
            const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return error.MalformedSubscription;
            _ = self.watched_entities.remove(parsed.id);
        } else {
            return error.MalformedSubscription;
        }
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
        var off: usize = 0;
        while (off < framed.len) {
            const n = write(self.fd, framed.ptr + off, framed.len - off);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.BrokenPipe;
            off += @intCast(n);
        }
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
