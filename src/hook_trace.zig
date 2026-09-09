//! Opt-in hook / event TRACING (#858, child of the hooks epic #854).
//!
//! Static route inspection (labelle-assembler#724) answers *"who COULD
//! receive this event?"*. This answers the four questions it cannot:
//!
//!   * was the emission actually **queued** — or did the enqueue fail?
//!   * which **drain** delivered it, and on which frame?
//!   * which **handlers ran**, in what order?
//!   * for a consumable event, **where did propagation stop**?
//!
//! ## Off by default, and off costs nothing
//!
//! Tracing is a **comptime** feature keyed off a single declaration in
//! the compilation root (the assembler-generated `main.zig`, or a
//! hand-written executable root):
//!
//! ```zig
//! pub const labelle_hook_trace = true;
//! // …or, with options:
//! pub const labelle_hook_trace: engine.HookTraceOptions = .{
//!     .ring_capacity = 512,
//!     .payload_capacity = 48,
//! };
//! ```
//!
//! With no such declaration `enabled` is `false`, every trace call site
//! is inside `if (comptime hook_trace.enabled)`, and `Game`'s tracer
//! field is `void`. There is no branch, no format call, no string and no
//! byte of state in a build that does not opt in — the emit/dispatch
//! paths lower to exactly the code they lowered to before #858.
//!
//! > `zig test` makes **Zig's test runner** the compilation root, not the
//! > test file, so an ordinary unit test can never turn tracing on. The
//! > same constraint #855's `HookContext.game()` hit. `test/hook_trace_root_exe.zig`
//! > is the executable harness that does.
//!
//! ## What it does NOT do
//!
//! * It never emits an event. The tracer writes to its own ring buffer
//!   and (optionally) to a caller-supplied sink; it does not touch the
//!   event bus, so a trace can never perturb ordering or re-entrancy.
//! * It never allocates. The ring is a fixed inline array sized at
//!   comptime, and every string it stores is a comptime literal
//!   (`@tagName`, `@typeName`, a declared id) with program lifetime.
//! * It does not serialize payload values by default. See
//!   `Options.payload_capacity` — payload capture needs BOTH a comptime
//!   budget and a runtime opt-in, and even then only scalar fields
//!   (ints, floats, bools, enums) are rendered. Slices and pointers are
//!   never dereferenced: the delivery contract (§5) makes them borrowed,
//!   and a tracer that read them would be reading someone else's memory
//!   at an arbitrary later time.
//!
//! ## Identity
//!
//! Trace records label receivers with the SAME id
//! labelle-assembler#723 gave them: the receiver's source path relative
//! to the generated target root, minus `.zig` — `hooks/animation_hooks`,
//! `packs/citizens/hooks/needs_hooks`, `scripts/flows/hit_counter`. See
//! `ReceiverId` for exactly how close the engine can get on its own, and
//! `HOOK-TRACING.md` §6 for what the assembler would have to emit to
//! make it exact rather than derived.

const std = @import("std");

// ── Build-time configuration ───────────────────────────────────────────

/// Tracing options, declared on the compilation root as
/// `pub const labelle_hook_trace: engine.HookTraceOptions = .{ … };`.
pub const Options = struct {
    /// How many records the in-process ring holds. Storage is
    /// `ring_capacity * @sizeOf(Record)` bytes inline on `Game`, so this
    /// is the whole memory cost of tracing. `0` is legal and means
    /// "sink-only": records are still filtered and handed to the sink,
    /// but nothing is retained.
    ring_capacity: usize = 128,
    /// Per-record byte budget for rendered payload scalars. `0` (the
    /// default) removes the payload buffer from `Record` entirely AND
    /// removes the comptime field walk from every trace call site, so a
    /// build that does not ask for payloads pays nothing for them.
    payload_capacity: usize = 0,
};

/// The decl the compilation root uses to turn tracing on.
pub const root_decl = "labelle_hook_trace";

const Resolved = struct { on: bool, options: Options };

const resolved: Resolved = blk: {
    const root = @import("root");
    if (!@hasDecl(root, root_decl)) break :blk .{ .on = false, .options = .{} };
    const v = @field(root, root_decl);
    const T = @TypeOf(v);
    if (T == bool) break :blk .{ .on = v, .options = .{} };
    if (T == Options) break :blk .{ .on = true, .options = v };
    @compileError(
        "`pub const " ++ root_decl ++ "` on the compilation root must be a " ++
            "`bool` or an `engine.HookTraceOptions`, got " ++ @typeName(T) ++ ".",
    );
};

/// True when this compilation opted into hook tracing. Every trace call
/// site in the engine is guarded by `if (comptime hook_trace.enabled)`.
pub const enabled: bool = resolved.on;

/// The resolved options. Meaningful only when `enabled`.
pub const options: Options = resolved.options;

// ── Record shape ───────────────────────────────────────────────────────

/// What the record is about. The set is deliberately small: every phase
/// answers a question a game author actually asks when an event "did not
/// arrive".
pub const Phase = enum {
    /// The event entered the frame buffer. `source` says through which
    /// API (`emit` or `try_emit`).
    enqueue,
    /// The enqueue FAILED and the event was never queued. `err` carries
    /// the error name. `emit` swallowed it; `try_emit` returned it.
    enqueue_failed,
    /// A `dispatchEvents` drain started. `count` is the snapshot size.
    drain_begin,
    /// That drain finished. `count` is the number of events it delivered.
    drain_end,
    /// One event began fan-out to the receiver tuple. `consumable` says
    /// which dispatch flavour applies.
    dispatch_begin,
    /// One receiver's handler is about to run. Records emitted by that
    /// handler therefore appear AFTER this one.
    deliver,
    /// The preceding `deliver` returned `true` on a consumable event:
    /// propagation stopped here and no later receiver ran.
    consumed,
    /// Fan-out finished. `count` is how many handlers ran. `count == 0`
    /// with no `deliver` between the `dispatch_begin`/`dispatch_end`
    /// pair means the event reached nobody.
    dispatch_end,

    pub fn label(self: Phase) []const u8 {
        return @tagName(self);
    }
};

/// Which engine API the record came through. Together with `Phase` this
/// is what distinguishes queued delivery from immediate delivery.
pub const Source = enum {
    /// `Game.emit` — buffered, infallible.
    emit,
    /// `Game.tryEmit` — buffered, fallible (#856).
    try_emit,
    /// `Game.emitSync` — immediate, bypasses the buffer AND the
    /// script-contract inbox (delivery contract §1).
    emit_sync,
    /// `Game.emitHook` — the engine's own closed `HookPayload`, always
    /// immediate.
    emit_hook,
    /// Delivery from inside a `Game.dispatchEvents` drain.
    drain,

    pub fn label(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// How the receiver id in a record was obtained.
pub const IdKind = enum {
    /// The receiver declared `pub const labelle_receiver_id = "…"`, so
    /// the id is EXACTLY labelle-assembler#723's `Receiver.id`.
    declared,
    /// Derived from `@typeName` (see `ReceiverId`). Correct for every
    /// assembler-generated layout today, but a derivation, not a
    /// contract.
    derived,
};

/// One trace record. Fixed size, no owned memory: every string field is
/// either a comptime literal (`@tagName`/`@typeName`/a declared id) or an
/// error name, all of which have program lifetime.
pub const Record = struct {
    /// Monotonic per-tracer record number. Never reset by the ring, so a
    /// gap in `seq` across retained records is exactly the overwrite.
    seq: u64 = 0,
    /// `Game.frame_number` when the record was taken.
    frame: u64 = 0,
    /// Which drain this record belongs to. `0` before the first
    /// `dispatchEvents`; a `dispatch_begin` with `source == .emit_sync`
    /// carries the drain number of the LAST completed drain, which is
    /// what makes "this ran between drain 7 and drain 8" readable.
    drain: u64 = 0,
    phase: Phase = .enqueue,
    source: Source = .emit,
    /// The event/payload variant name — `@tagName` of the active tag.
    event: []const u8 = "",
    /// Receiver id (see `ReceiverId`), or `""` on a record that is not
    /// receiver-scoped.
    receiver: []const u8 = "",
    /// The receiver's Zig `@typeName`. Always present alongside
    /// `receiver`, so a derived id is never the only thing you have.
    receiver_type: []const u8 = "",
    receiver_id_kind: IdKind = .derived,
    /// Receiver position in the dispatch tuple — the order
    /// labelle-assembler#723's `buildReceiverPlan` resolved.
    index: u16 = 0,
    /// Phase-dependent count: buffered events for `drain_begin`,
    /// delivered events for `drain_end`, handlers run for
    /// `dispatch_end`.
    count: u32 = 0,
    /// True when the variant's payload declares `pub const consumable =
    /// true` and the return-aware dispatch path is in force.
    consumable: bool = false,
    /// `@errorName` on `enqueue_failed`, else `""`.
    err: []const u8 = "",

    payload_len: u16 = 0,
    payload_buf: [options.payload_capacity]u8 = undefined,

    /// Rendered payload scalars, or `""` when payload capture is off.
    pub fn payload(self: *const Record) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }

    /// Human-readable single line. Stable field ORDER is the contract;
    /// the exact spacing is not.
    ///
    /// ```text
    /// 000012 f3 d2 deliver       drain      t__claim         #1 packs/citizens/hooks/needs_hooks
    /// ```
    pub fn writeText(self: *const Record, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>6} f{d} d{d} {s:<14} {s:<10} {s}", .{
            self.seq,             self.frame,            self.drain,
            @tagName(self.phase), @tagName(self.source), self.event,
        });
        if (self.consumable) try w.writeAll(" [consumable]");
        if (self.receiver.len != 0) {
            try w.print(" #{d} {s}", .{ self.index, self.receiver });
            if (self.receiver_id_kind == .derived) try w.writeAll("~");
        }
        switch (self.phase) {
            .enqueue, .enqueue_failed, .drain_begin, .drain_end, .dispatch_end => try w.print(" count={d}", .{self.count}),
            else => {},
        }
        if (self.err.len != 0) try w.print(" err={s}", .{self.err});
        if (self.payload_len != 0) try w.print(" payload={{{s}}}", .{self.payload()});
        try w.writeByte('\n');
    }

    /// One JSON object, no trailing newline. `writeJsonLines` joins them
    /// into JSONL — a stream-friendly, bounded, append-only format that
    /// survives a truncated trace, which a single JSON array does not.
    ///
    /// Keys are stable; new keys may be ADDED in a future version, so
    /// consumers must ignore unknown ones.
    pub fn writeJson(self: *const Record, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            \\{{"seq":{d},"frame":{d},"drain":{d},"phase":"{s}","source":"{s}","event":
        , .{
            self.seq,              self.frame,
            self.drain,            @tagName(self.phase),
            @tagName(self.source),
        });
        try jsonString(self.event, w);
        if (self.receiver.len != 0) {
            try w.writeAll(",\"receiver\":");
            try jsonString(self.receiver, w);
            try w.writeAll(",\"receiver_type\":");
            try jsonString(self.receiver_type, w);
            try w.print(",\"receiver_id_kind\":\"{s}\",\"index\":{d}", .{
                @tagName(self.receiver_id_kind), self.index,
            });
        }
        switch (self.phase) {
            .enqueue, .enqueue_failed, .drain_begin, .drain_end, .dispatch_end => try w.print(",\"count\":{d}", .{self.count}),
            else => {},
        }
        if (self.consumable) try w.writeAll(",\"consumable\":true");
        if (self.err.len != 0) {
            try w.writeAll(",\"error\":");
            try jsonString(self.err, w);
        }
        if (self.payload_len != 0) {
            try w.writeAll(",\"payload\":");
            try jsonString(self.payload(), w);
        }
        try w.writeByte('}');
    }
};

/// JSON string escaping, quotes included. Uses std's encoder rather than
/// `std.zig.fmtString` — the two escape sets differ (`\xNN` is not JSON),
/// and this output is read by other processes.
fn jsonString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    std.json.Stringify.encodeJsonString(s, .{}, w) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
    };
}

// ── Filtering ──────────────────────────────────────────────────────────

/// Name filter for events and for receivers. Patterns are matched
/// literally, except that a trailing `*` makes the rest a prefix:
/// `"packs/citizens/*"`, `"engine__*"`.
///
/// Filtering NEVER affects dispatch. It only decides whether a record is
/// recorded — a filtered-out record is not counted as dropped either,
/// because it was never wanted.
pub const Filter = struct {
    /// `null` admits everything. A non-null list admits only names that
    /// match one of its patterns.
    include: ?[]const []const u8 = null,
    /// Always rejects, and wins over `include`.
    exclude: []const []const u8 = &.{},

    pub fn admits(self: Filter, name: []const u8) bool {
        if (matchesAny(self.exclude, name)) return false;
        if (self.include) |inc| return matchesAny(inc, name);
        return true;
    }
};

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (p.len != 0 and p[p.len - 1] == '*') {
            if (std.mem.startsWith(u8, name, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// What happens when the ring is full.
pub const Overflow = enum {
    /// Keep the newest `ring_capacity` records; count the evictions.
    /// Right for "what happened just before the bug".
    overwrite_oldest,
    /// Keep the oldest; count the refusals. Right for "what happened at
    /// startup".
    drop_newest,
};

// ── Receiver identity ──────────────────────────────────────────────────

/// The decl a hook receiver can carry to name itself EXACTLY as
/// labelle-assembler#723's `Receiver.id` does:
///
/// ```zig
/// pub const AnimationHooks = struct {
///     pub const labelle_receiver_id = "hooks/animation_hooks";
///     …
/// };
/// ```
///
/// A `pub const` string is invisible to `MergeHooks`' handler validation
/// (which only rejects two-parameter `pub fn`s whose name is not an event),
/// so declaring it is always safe.
pub const receiver_id_decl = "labelle_receiver_id";

/// Comptime receiver identity, memoized per receiver type — Zig caches
/// generic struct instantiations, so the `@typeName` walk below runs
/// ONCE per receiver type rather than once per (receiver x variant),
/// which is what keeps tracing's comptime cost linear in receivers.
pub fn ReceiverId(comptime Base: type) type {
    return struct {
        pub const type_name: []const u8 = @typeName(Base);
        pub const kind: IdKind = if (declared(Base) == null) .derived else .declared;
        pub const id: []const u8 = declared(Base) orelse deriveFromTypeName(@typeName(Base));
    };
}

fn declared(comptime Base: type) ?[]const u8 {
    if (@typeInfo(Base) != .@"struct" and @typeInfo(Base) != .@"union" and @typeInfo(Base) != .@"enum") return null;
    if (!@hasDecl(Base, receiver_id_decl)) return null;
    const v = @field(Base, receiver_id_decl);
    const info = @typeInfo(@TypeOf(v));
    // Accept `[]const u8` and the `*const [N:0]u8` a bare literal has.
    if (info != .pointer) return null;
    return v;
}

/// Best-effort derivation of #723's receiver id from `@typeName`.
///
/// Zig names a file-scope type by its module-relative path with `/`
/// replaced by `.`, plus the declaration name:
///
/// ```text
/// hooks/animation_hooks.zig  →  hooks.animation_hooks.AnimationHooks
/// packs/citizens/hooks/needs_hooks.zig
///                            →  packs.citizens.hooks.needs_hooks.NeedsHooks
/// ```
///
/// and the generated `main.zig` IS the module root, which is exactly the
/// "generated target root" #723 makes its ids relative to. So dropping
/// the final `.Name` and mapping `.` back to `/` reproduces the id.
///
/// **This is a derivation, not a contract.** It is wrong if a receiver
/// type is nested inside another type, if a directory name contains a
/// `.`, or if a future Zig changes `@typeName`'s shape. A receiver that
/// declares `labelle_receiver_id` (above) is never derived, and every
/// record carries `receiver_type` so the raw truth is always available.
fn deriveFromTypeName(comptime tn: []const u8) []const u8 {
    comptime {
        // Generic instantiations (`MergeHooks(…)`) and anything else with
        // punctuation are not file paths — leave them alone.
        for (tn) |c| {
            if (c == '(' or c == ' ' or c == ',') return tn;
        }
        const cut = std.mem.lastIndexOfScalar(u8, tn, '.') orelse return tn;
        if (cut == 0) return tn;
        var buf: [cut]u8 = undefined;
        for (tn[0..cut], 0..) |c, i| buf[i] = if (c == '.') '/' else c;
        const out = buf;
        return &out;
    }
}

/// True when `T` declares `pub const consumable = true` — the marker that
/// switches `MergeHooks.emit` to the return-aware path (RFC-PLUGIN-EVENTS
/// O4). Mirrors `labelle-core`'s private `isConsumable` so the traced
/// dispatch can report the flavour AND reproduce the break; the traced
/// and untraced paths are pinned to agree by
/// `test/hook_trace_root_exe.zig`.
pub fn isConsumable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (!@hasDecl(T, "consumable")) return false;
    const decl_type = @TypeOf(@field(T, "consumable"));
    if (decl_type != bool and decl_type != comptime_int) return false;
    return @field(T, "consumable") == true;
}

// ── Payload rendering ──────────────────────────────────────────────────

/// Render a payload's SCALAR fields into `buf`, returning the length.
///
/// Only ints, floats, bools and enums are rendered. Slices, pointers,
/// nested aggregates and opaques are skipped entirely and never
/// dereferenced — the delivery contract makes payload slices *borrowed*
/// (§5), and a ring buffer read minutes later would be reading memory
/// its owner has long since reused.
pub fn renderScalars(comptime T: type, value: T, buf: []u8) u16 {
    if (buf.len == 0) return 0;
    var w = std.Io.Writer.fixed(buf);
    if (@typeInfo(T) != .@"struct") return 0;
    var first = true;
    inline for (std.meta.fields(T)) |f| {
        const keep = switch (@typeInfo(f.type)) {
            .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => true,
            else => false,
        };
        if (keep) {
            if (!first) w.writeAll(" ") catch return @intCast(w.end);
            first = false;
            switch (@typeInfo(f.type)) {
                .@"enum" => w.print("{s}=.{s}", .{ f.name, @tagName(@field(value, f.name)) }) catch return @intCast(w.end),
                else => w.print("{s}={any}", .{ f.name, @field(value, f.name) }) catch return @intCast(w.end),
            }
        }
    }
    return @intCast(w.end);
}

// ── The tracer ─────────────────────────────────────────────────────────

/// The per-`Game` trace buffer. Reached as `game.hook_tracer` in a build
/// that opted in; `Game.hook_tracer` is `void` otherwise.
pub const Tracer = struct {
    pub const capacity: usize = options.ring_capacity;

    /// A live consumer of trace records — a log line, a socket, a file.
    ///
    /// The sink runs INSIDE the emit/dispatch path, on the emitting
    /// thread. It must not emit events, must not call back into
    /// `dispatchEvents`, and should be cheap. A sink that re-enters the
    /// tracer is detected and its nested record is dropped (counted in
    /// `dropped_reentrant`) rather than recursing.
    pub const Sink = struct {
        ctx: ?*anyopaque = null,
        onRecord: *const fn (ctx: ?*anyopaque, rec: *const Record) void,
    };

    /// Runtime master switch. `true` in a traced build; set it to
    /// `false` to pause recording without rebuilding.
    active: bool = true,
    /// Runtime half of the payload opt-in. Comptime
    /// `options.payload_capacity > 0` is the other half; BOTH are
    /// required before any payload value is rendered.
    capture_payloads: bool = false,
    overflow: Overflow = .overwrite_oldest,
    /// Filters the `event` name of every record.
    events: Filter = .{},
    /// Filters the `receiver` id of receiver-scoped records only.
    /// Non-receiver records (enqueue, drain, dispatch bounds) are
    /// unaffected.
    receivers: Filter = .{},
    sink: ?Sink = null,

    ring: [capacity]Record = undefined,
    /// Index of the oldest retained record.
    head: usize = 0,
    /// Number of retained records.
    len: usize = 0,
    /// Records lost to the bound (evicted or refused, per `overflow`).
    /// Reported by `writeSummary`; a trace with a non-zero value here is
    /// incomplete and says so.
    dropped: u64 = 0,
    /// Records dropped because a sink re-entered the tracer. Kept
    /// separate: this one is a bug in the sink, not a capacity problem.
    dropped_reentrant: u64 = 0,
    /// Next `Record.seq`.
    seq: u64 = 0,
    /// Monotonic drain counter — only ever incremented, never restored.
    /// Allocates the id; it does NOT say which drain is running.
    drain_seq: u64 = 0,
    /// The drain currently being processed, which is what records are
    /// stamped with. Saved and restored around a drain, so a NESTED
    /// `dispatchEvents` (a handler that drains) does not steal the outer
    /// drain's number: previously the outer `drain_end` — and every outer
    /// deliver/enqueue after the nested call — reported the INNER id
    /// (#858 review).
    current_drain: u64 = 0,
    /// Nesting depth of `dispatchEvents`. Only needed to answer "is a drain
    /// still running?" when one ends: at depth 0 `current_drain` returns to
    /// tracking `drain_seq`, so an enqueue made OUTSIDE any drain is stamped
    /// with the number of drains completed — the pre-existing meaning, which
    /// `hook_trace_root_exe` pins ("the enqueue predates the drain it landed
    /// in").
    drain_depth: u16 = 0,
    in_sink: bool = false,

    /// Record `rec`, filling in `seq`. Filtered-out records are not
    /// recorded and not counted as dropped.
    pub fn push(self: *Tracer, rec_in: Record) void {
        if (!self.active) return;
        if (!self.events.admits(rec_in.event)) return;
        if (rec_in.receiver.len != 0 and !self.receivers.admits(rec_in.receiver)) return;

        // Reentrancy is decided BEFORE any mutation. Recording first and
        // rejecting after burned a `seq` and wrote the ring for a record
        // the tracer then counted as dropped — the trace showed a gap in
        // sequence numbers AND a retained record for the same event, so
        // `dropped_reentrant` could not be reconciled against `seq`
        // (#858 review). A rejected record must leave no trace at all.
        if (self.sink != null and self.in_sink) {
            self.dropped_reentrant += 1;
            return;
        }

        var rec = rec_in;
        rec.seq = self.seq;
        self.seq += 1;

        if (capacity == 0) {
            self.dropped += 1;
        } else if (self.len < capacity) {
            self.ring[(self.head + self.len) % capacity] = rec;
            self.len += 1;
        } else switch (self.overflow) {
            .overwrite_oldest => {
                self.ring[self.head] = rec;
                self.head = (self.head + 1) % capacity;
                self.dropped += 1;
            },
            .drop_newest => self.dropped += 1,
        }

        if (self.sink) |s| {
            // The reentrancy guard ran above, before any state changed.
            self.in_sink = true;
            defer self.in_sink = false;
            s.onRecord(s.ctx, &rec);
        }
    }

    /// Retained record `i`, oldest first.
    pub fn at(self: *const Tracer, i: usize) *const Record {
        std.debug.assert(i < self.len);
        // `capacity == 0` is a DOCUMENTED configuration (sink-only: records
        // are filtered and handed to the sink, nothing retained). `% 0` is
        // illegal, so the modulo cannot be reached in that build — `len` is
        // always 0 there, making this unreachable rather than merely
        // unlikely. Spelled out so a renderer written against `capacity`
        // instead of `count()` fails loudly at the assert above rather than
        // dividing by zero (#858 review).
        if (comptime capacity == 0) unreachable;
        return &self.ring[(self.head + i) % capacity];
    }

    /// How many records are retained (never more than `capacity`).
    pub fn count(self: *const Tracer) usize {
        return self.len;
    }

    /// Drop every retained record. Counters (`seq`, `dropped`,
    /// `drain_seq`) are NOT reset — they are the honesty of the trace.
    pub fn clear(self: *Tracer) void {
        self.head = 0;
        self.len = 0;
    }

    /// Human-readable dump: one line per record, then the summary.
    pub fn writeText(self: *const Tracer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.len) |i| try self.at(i).writeText(w);
        try self.writeSummary(w);
    }

    /// JSON Lines dump: one `Record` object per line, then a final
    /// `{"summary":…}` object. Bounded, append-only, and valid even when
    /// truncated — which is why it is JSONL and not one array.
    pub fn writeJsonLines(self: *const Tracer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.len) |i| {
            try self.at(i).writeJson(w);
            try w.writeByte('\n');
        }
        try w.print(
            \\{{"summary":{{"retained":{d},"capacity":{d},"recorded":{d},"dropped":{d},"dropped_reentrant":{d},"drains":{d}}}}}
        , .{ self.len, capacity, self.seq, self.dropped, self.dropped_reentrant, self.drain_seq });
        try w.writeByte('\n');
    }

    /// One line stating exactly how complete the trace is.
    pub fn writeSummary(self: *const Tracer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "-- hook trace: {d}/{d} retained, {d} recorded, {d} dropped, {d} dropped(reentrant), {d} drains\n",
            .{ self.len, capacity, self.seq, self.dropped, self.dropped_reentrant, self.drain_seq },
        );
    }
};

// ── Off-build stand-in ─────────────────────────────────────────────────

/// The type of `Game.hook_tracer`: the real `Tracer` in a traced build,
/// `void` otherwise. `@sizeOf(void) == 0`, so an untraced `Game` is
/// byte-for-byte the size it was before #858.
pub const TracerField = if (enabled) Tracer else void;

pub const tracer_init: TracerField = if (enabled) .{} else {};
