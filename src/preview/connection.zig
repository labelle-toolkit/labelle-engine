//! The `Preview` connect-out control channel struct: fields, the
//! connection lifecycle (connect / deinit / hello / heartbeat / bye),
//! the input-event queue, the subscription/handshake accessors, and
//! the low-level JSON `writeFrame`.
//!
//! The bulk per-concern logic lives in sibling modules and is exposed
//! here as thin delegating methods so the public `Preview` API surface
//! stays identical:
//!  - `frame_stream.zig` — PIE viewport SHM/IOSurface producer
//!  - `telemetry.zig`     — binary telemetry frames + subscription poll
//!
//! Split out of `preview_mode.zig` verbatim; behavior-preserving.

const std = @import("std");

const protocol = @import("protocol.zig");
const socket = @import("socket.zig");
const frame_stream = @import("frame_stream.zig");
const telemetry = @import("telemetry.zig");

const preview_shm = protocol.preview_shm;
const preview_iosurface = protocol.preview_iosurface;

const ByeReason = protocol.ByeReason;
const FrameHandshakeState = protocol.FrameHandshakeState;
const FrameOffer = protocol.FrameOffer;
const InputEvent = protocol.InputEvent;
const PendingResize = protocol.PendingResize;
const SnapshotComponent = protocol.SnapshotComponent;
const ConnectError = protocol.ConnectError;
const WriteError = protocol.WriteError;
const PollError = protocol.PollError;
const PublishErrorT = protocol.PublishError;
const protocol_version = protocol.protocol_version;
const heartbeat_interval_ms = protocol.heartbeat_interval_ms;
const input_queue_capacity = protocol.input_queue_capacity;

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
    /// PIE viewport handshake state (#543). The producer-side render
    /// loop is expected to gate `frame_published` on
    /// `frame_state == .accepted`.
    frame_state: FrameHandshakeState = .not_offered,
    /// Set by the editor's `frame_resize`; cleared by `takeResize`.
    /// `null` means "no resize pending."
    pending_resize: ?PendingResize = null,
    /// SHM ring writer for #544. `null` until `beginFrameStream` runs;
    /// `endFrameStream` deallocates and resets to `null`.
    frame_producer: ?preview_shm.Producer = null,
    /// macOS IOSurface ring writer for #547. `null` until
    /// `beginFrameStreamIOSurface` runs; `endFrameStreamIOSurface`
    /// deallocates and resets to `null`. Mutually exclusive with
    /// `frame_producer` on the same `Preview` instance — the two
    /// `begin*` entry points reject if the other mode is already
    /// active.
    frame_iosurface_producer: ?preview_iosurface.Producer = null,
    /// Owned shm_name backing `frame_producer`. Allocated per
    /// `beginFrameStream` and freed at the start of the next call
    /// (or in `endFrameStream` / `deinit`). Previously dupe'd into
    /// `subs_arena`, which is only freed at full `Preview` deinit —
    /// resize-driven re-offer cycles would otherwise leak names
    /// proportional to the resize count (#546 review).
    frame_shm_name: ?[:0]u8 = null,
    /// Monotonic frame counter — bumped by `publishFrame` (or
    /// `publishFrameIOSurface`).
    frame_index: u64 = 0,
    /// Fixed-capacity ring of input events parsed from editor → game
    /// JSON frames (`mouse_pos`, `mouse_button`). The game drains via
    /// `popInputEvent` each frame and forwards to its input sinks.
    /// Overflow drops the oldest event — input lag is preferable to
    /// allocator pressure on the producer hot path (#143).
    input_buf: [input_queue_capacity]InputEvent = undefined,
    input_head: usize = 0,
    input_tail: usize = 0,
    input_count: usize = 0,

    /// Errors specific to `beginFrameStream` / `publishFrame` (and the
    /// IOSurface variants). Kept reachable as `Preview.PublishError`
    /// for back-compat — the definition lives in `protocol.zig`.
    pub const PublishError = PublishErrorT;

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
        socket.socketClose(self.fd);
        // Tear down the SHM ring if a stream was started; safe no-op
        // when never started.
        if (self.frame_producer) |*p| {
            p.deinit();
            self.frame_producer = null;
        }
        // Same for the IOSurface ring (mutually exclusive with the
        // SHM ring at runtime — only one of the two should be non-
        // null at any point — but `deinit` defensively cleans both
        // so a half-initialised state can't leak).
        if (self.frame_iosurface_producer) |*p| {
            p.deinit();
            self.frame_iosurface_producer = null;
        }
        if (self.frame_shm_name) |old| {
            self.inbox_alloc.free(old);
            self.frame_shm_name = null;
        }
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

    // ── PIE viewport handshake (#543) ──────────────────────────────

    /// Offer the editor a SHM pixel ring. Call once the producer has
    /// bound the region; transitions `frame_state` to `.offered`.
    /// The producer should withhold any `frame_published` notifications
    /// until the editor responds with `frame_accept`.
    pub fn sendFrameOffer(self: *Preview, offer: FrameOffer) WriteError!void {
        return frame_stream.sendFrameOffer(self, offer);
    }

    /// Optional sidecar to wake the editor on a new frame. The wire
    /// contract is "editor polls `Header.latest` to find the freshest
    /// slot" — this frame is informational (and useful for editors that
    /// want to throttle frame uploads to actual publishes rather than
    /// every render tick). Cheap when the editor doesn't care: a
    /// roughly 60-byte JSON line per produced frame.
    pub fn sendFramePublished(self: *Preview, frame_idx: u64, produce_ns: u64) WriteError!void {
        return frame_stream.sendFramePublished(self, frame_idx, produce_ns);
    }

    /// True once the editor has acknowledged the offer. Producer uses
    /// this as the gate on writing pixels into the SHM ring (no point
    /// rendering into a region nobody is reading from).
    pub fn isFrameAccepted(self: *const Preview) bool {
        return self.frame_state == .accepted;
    }

    /// Pop the pending resize request, if any. Clears the slot so a
    /// second call returns `null` until the editor sends another
    /// `frame_resize`. Producer responds by tearing down the current
    /// ring and re-issuing `sendFrameOffer` at the new dimensions.
    ///
    /// State invalidation (`.accepted → .not_offered`) happens
    /// *eagerly* in the `frame_resize` parser, not here — so
    /// producers gating publishes on `isFrameAccepted` see the
    /// stream go inactive the moment the editor sends the resize
    /// (#545 review).
    pub fn takeResize(self: *Preview) ?PendingResize {
        const pending = self.pending_resize;
        self.pending_resize = null;
        return pending;
    }

    // ── #544: PBO/SHM publish (producer side) ──────────────────────

    /// Allocate a SHM ring sized for `width x height` RGBA8 frames and
    /// emit a `frame_offer` over the control channel. See
    /// `frame_stream.beginFrameStream`.
    pub fn beginFrameStream(self: *Preview, width: u32, height: u32) PublishError!void {
        return frame_stream.beginFrameStream(self, width, height);
    }

    /// Publish a CPU-side RGBA8 frame into the SHM ring and emit an
    /// optional `frame_published` JSON sidecar. See
    /// `frame_stream.publishFrame`.
    pub fn publishFrame(self: *Preview, pixels: []const u8) PublishError!void {
        return frame_stream.publishFrame(self, pixels);
    }

    /// Tear down the SHM ring. Safe to call when no stream is active.
    /// Does **not** send a `bye` — caller still owns that lifecycle.
    pub fn endFrameStream(self: *Preview) void {
        return frame_stream.endFrameStream(self);
    }

    // ── #547: macOS IOSurface publish (producer side) ──────────────

    /// Allocate an IOSurface ring + control-plane shm region and emit
    /// a `frame_offer` with `format = "iosurface_bgra8"`. macOS-only.
    /// See `frame_stream.beginFrameStreamIOSurface`.
    pub fn beginFrameStreamIOSurface(self: *Preview, width: u32, height: u32) PublishError!void {
        return frame_stream.beginFrameStreamIOSurface(self, width, height);
    }

    /// Publish a CPU-side RGBA8 frame into the next IOSurface slot
    /// (swizzled to BGRA8). See `frame_stream.publishFrameIOSurface`.
    pub fn publishFrameIOSurface(self: *Preview, pixels: []const u8) PublishError!void {
        return frame_stream.publishFrameIOSurface(self, pixels);
    }

    /// Borrow the underlying `IOSurfaceRef` for slot N (Path-A render-
    /// to-surface). See `frame_stream.getIOSurfaceAt`.
    pub fn getIOSurfaceAt(self: *const Preview, slot: u32) ?preview_iosurface.IOSurfaceRef {
        return frame_stream.getIOSurfaceAt(self, slot);
    }

    /// Signal the editor that slot N's IOSurface has freshly-rendered
    /// content (Path-A publish). See `frame_stream.signalSlotReady`.
    pub fn signalSlotReady(self: *Preview, slot: u32) PublishError!void {
        return frame_stream.signalSlotReady(self, slot);
    }

    /// Tear down the IOSurface ring + control-plane shm region. Safe
    /// to call when no iosurface stream is active. See
    /// `frame_stream.endFrameStreamIOSurface`.
    pub fn endFrameStreamIOSurface(self: *Preview) void {
        return frame_stream.endFrameStreamIOSurface(self);
    }

    // ── Binary telemetry frames (Phase 2 / #518) ────────────────────

    /// Emit an `entity_created` binary frame. See
    /// `telemetry.emitEntityCreated`.
    pub fn emitEntityCreated(self: *Preview, entity_id: u64, prefab_name: ?[]const u8) WriteError!void {
        return telemetry.emitEntityCreated(self, entity_id, prefab_name);
    }

    /// Emit an `entity_destroyed` binary frame. See
    /// `telemetry.emitEntityDestroyed`.
    pub fn emitEntityDestroyed(self: *Preview, entity_id: u64) WriteError!void {
        return telemetry.emitEntityDestroyed(self, entity_id);
    }

    /// Emit a `component_changed` binary frame (no-op when not
    /// subscribed / not watched). See `telemetry.emitComponentChanged`.
    pub fn emitComponentChanged(
        self: *Preview,
        entity_id: u64,
        comp_name: []const u8,
        comp_bytes: []const u8,
    ) WriteError!void {
        return telemetry.emitComponentChanged(self, entity_id, comp_name, comp_bytes);
    }

    /// Emit a one-shot snapshot of an entity's components (N
    /// back-to-back `component_changed` frames). See
    /// `telemetry.emitEntitySnapshot`.
    pub fn emitEntitySnapshot(
        self: *Preview,
        entity_id: u64,
        components: []const SnapshotComponent,
    ) WriteError!void {
        return telemetry.emitEntitySnapshot(self, entity_id, components);
    }

    /// Emit a `node_entered` binary frame (no-op when the flow is not
    /// subscribed). See `telemetry.emitNodeEntered`.
    pub fn emitNodeEntered(self: *Preview, flow_name: []const u8, node_id: u32) WriteError!void {
        return telemetry.emitNodeEntered(self, flow_name, node_id);
    }

    /// Emit a `pin_value` binary frame (no-op when the flow's pin
    /// stream is not subscribed). See `telemetry.emitPinValue`.
    pub fn emitPinValue(
        self: *Preview,
        flow_name: []const u8,
        node_id: u32,
        pin_name: []const u8,
        value: f64,
    ) WriteError!void {
        return telemetry.emitPinValue(self, flow_name, node_id, pin_name, value);
    }

    /// Drain pending editor → engine subscription / input / handshake
    /// JSON frames. Non-blocking. See `telemetry.pollSubscription`.
    pub fn pollSubscription(self: *Preview) PollError!void {
        return telemetry.pollSubscription(self);
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

    /// Pop the next pending input event from the editor, or `null` when
    /// the queue is empty. Game frame loops drain in a `while (...) |ev|`
    /// loop after `pollSubscription` and forward each event to their
    /// input sinks (e.g. sokol_imgui's `add_*_event` family). #143.
    pub fn popInputEvent(self: *Preview) ?InputEvent {
        if (self.input_count == 0) return null;
        const ev = self.input_buf[self.input_head];
        self.input_head = (self.input_head + 1) % input_queue_capacity;
        self.input_count -= 1;
        return ev;
    }

    pub fn pushInputEvent(self: *Preview, ev: InputEvent) void {
        // Overflow policy: drop the oldest. Editors that hammer mouse_pos
        // shouldn't be able to stall the producer by filling the ring.
        if (self.input_count == input_queue_capacity) {
            self.input_head = (self.input_head + 1) % input_queue_capacity;
            self.input_count -= 1;
        }
        self.input_buf[self.input_tail] = ev;
        self.input_tail = (self.input_tail + 1) % input_queue_capacity;
        self.input_count += 1;
    }

    /// Phase 3 (#534) entity-scope check. Returns `true` when the
    /// caller should emit for `entity_id`. The "empty set means watch
    /// everything" rule lives here so call sites stay free of policy.
    pub fn isEntityWatched(self: *const Preview, entity_id: u64) bool {
        if (self.watched_entities.count() == 0) return true;
        return self.watched_entities.contains(entity_id);
    }

    // ── Internals ───────────────────────────────────────────────────

    pub fn writeFrame(self: *Preview, msg: anytype) WriteError!void {
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
            const n = socket.socketWrite(self.fd, framed.ptr + off, framed.len - off);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.BrokenPipe;
            off += @intCast(n);
        }
    }
};
