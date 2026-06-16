//! Binary telemetry frame emitters (Phase 2 / #518), the editor →
//! engine subscription-frame parser, and the non-blocking inbox drain.
//!
//! Free functions operating on `*Preview` — the public methods on the
//! `Preview` struct (in `connection.zig`) are thin wrappers that
//! delegate here. Split out of `preview_mode.zig` verbatim;
//! behavior-preserving.

const std = @import("std");

const protocol = @import("protocol.zig");
const socket = @import("socket.zig");
const connection = @import("connection.zig");

const Preview = connection.Preview;
const BinaryFrameKind = protocol.BinaryFrameKind;
const InputEvent = protocol.InputEvent;
const SnapshotComponent = protocol.SnapshotComponent;
const WriteError = protocol.WriteError;
const PollError = protocol.PollError;
const binary_magic = protocol.binary_magic;

// ── Binary telemetry frames (Phase 2 / #518) ────────────────────────

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
    try writeBinaryFrame(self, .entity_created, buf);
}

/// Emit an `entity_destroyed` binary frame.
///
/// Payload layout: `[u64 entity_id]`. Always emits.
pub fn emitEntityDestroyed(self: *Preview, entity_id: u64) WriteError!void {
    var buf: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &buf, entity_id, .little);
    try writeBinaryFrame(self, .entity_destroyed, &buf);
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
    try writeComponentChangedFrame(self, entity_id, comp_name, comp_bytes);
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
        try writeComponentChangedFrame(self, entity_id, c.name, c.bytes);
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
    try writeBinaryFrame(self, .component_changed, buf);
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
    try writeBinaryFrame(self, .node_entered, buf);
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
    try writeBinaryFrame(self, .pin_value, buf);
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
    try fillInboxNonBlocking(self);

    while (true) {
        const nl_idx = std.mem.indexOfScalar(u8, self.inbox.items, '\n') orelse break;
        const line = self.inbox.items[0..nl_idx];
        try applySubscriptionFrame(self, line);
        // Drop the consumed line (including the `\n`).
        const remaining = self.inbox.items.len - (nl_idx + 1);
        std.mem.copyForwards(u8, self.inbox.items[0..remaining], self.inbox.items[nl_idx + 1 ..]);
        self.inbox.shrinkRetainingCapacity(remaining);
    }
}

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
        const n = socket.socketWrite(self.fd, framed.ptr + off, framed.len - off);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.BrokenPipe;
        off += @intCast(n);
    }
}

fn fillInboxNonBlocking(self: *Preview) PollError!void {
    // Cross-platform non-blocking drain. POSIX: fcntl(F_GETFL/F_SETFL)
    // toggles O_NONBLOCK around a tight read loop (#545 fixed the
    // variadic-fcntl ABI bug that made the toggle silently no-op on
    // aarch64-darwin). Windows: `ioctlsocket(FIONBIO, 1)` is the
    // equivalent toggle — see `setNonBlocking`. We restore the
    // original mode on exit so subsequent blocking writes aren't
    // surprised. The socket stays blocking for writes elsewhere so
    // partial sends aren't a concern.
    const fd = self.fd;
    // setNonBlocking failure propagates as `InputOutput`. Silently
    // returning here would leave the socket blocking, and the
    // first `read` below would stall the entire frame loop — the
    // exact bug the variadic-fcntl ABI fix uncovered (#545
    // review).
    const state = socket.setNonBlocking(fd) orelse return error.InputOutput;
    defer socket.restoreBlocking(fd, state);

    var scratch: [1024]u8 = undefined;
    while (true) {
        const n = socket.socketRead(fd, @ptrCast(&scratch[0]), scratch.len);
        if (n < 0) {
            if (socket.wouldBlock()) return;
            return error.InputOutput;
        }
        if (n == 0) return; // EOF — caller infers from subsequent write failures.
        try self.inbox.appendSlice(self.inbox_alloc, scratch[0..@intCast(n)]);
    }
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
    } else if (std.mem.eql(u8, kind_only.kind, "frame_accept")) {
        // Editor acknowledges a prior `frame_offer`. The transition
        // is `.offered → .accepted`; from any other state we ignore
        // (an editor that ACKs a stale offer after a resize won't
        // tip us back into the wrong state).
        if (self.frame_state == .offered) {
            self.frame_state = .accepted;
        }
    } else if (std.mem.eql(u8, kind_only.kind, "mouse_pos")) {
        const Parsed = struct { kind: []const u8, x: f32, y: f32 };
        const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedSubscription;
        self.pushInputEvent(.{ .mouse_pos = .{ .x = parsed.x, .y = parsed.y } });
    } else if (std.mem.eql(u8, kind_only.kind, "mouse_button")) {
        const Parsed = struct { kind: []const u8, button: i32, down: bool };
        const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedSubscription;
        self.pushInputEvent(.{ .mouse_button = .{ .button = parsed.button, .down = parsed.down } });
    } else if (std.mem.eql(u8, kind_only.kind, "frame_resize")) {
        const Parsed = struct { kind: []const u8, width: u32, height: u32 };
        const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedSubscription;
        self.pending_resize = .{ .width = parsed.width, .height = parsed.height };
        // Invalidate the handshake *immediately* — between the
        // editor's resize request and the backend's
        // `takeResize`/`beginFrameStream` re-offer cycle, the
        // current ring is stale. Producers gating publishes on
        // `isFrameAccepted` must see false in that window
        // (#545 review).
        self.frame_state = .not_offered;
    } else {
        return error.MalformedSubscription;
    }
}
