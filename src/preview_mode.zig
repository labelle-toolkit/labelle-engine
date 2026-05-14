//! Preview mode — STUBBED for Zig 0.16 migration.
//!
//! The original preview module wired the engine to the labelle-gui
//! editor over a TCP control plane (`std.net.Stream` + binary
//! state-telemetry frames). Zig 0.16 reshaped `std.net` into
//! `std.Io.net` with `Io`-threaded blocking semantics, so the real
//! transport plumbing needs a full rewrite. To unblock the rest of
//! the labelle-toolkit 0.16 migration we keep the public API surface
//! (so `game.zig` and `root.zig` re-exports still compile) but make
//! every method a no-op that returns `error.PreviewDisabled`.
//!
//! TODO: restore real preview behavior on top of `std.Io.net` with a
//! background thread for blocking accept/read, or polling via the new
//! `Io` cancellation handles. The state machine shape can stay
//! identical to the pre-0.16 design — only the transport plumbing
//! changes.

const std = @import("std");

// ── Public types (unchanged shape — re-exported via root.zig) ─────

pub const ByeReason = enum {
    user_quit,
    crash,
    timeout,
    protocol_error,
    unknown,

    pub fn asString(self: ByeReason) []const u8 {
        return switch (self) {
            .user_quit => "user_quit",
            .crash => "crash",
            .timeout => "timeout",
            .protocol_error => "protocol_error",
            .unknown => "unknown",
        };
    }
};

pub const protocol_version: u32 = 1;

pub const binary_magic: u8 = 0x1B;

pub const BinaryFrameKind = enum(u8) {
    entity_created = 0x01,
    entity_destroyed = 0x02,
    component_changed = 0x03,
    entity_snapshot = 0x04,
    node_entered = 0x05,
};

pub const heartbeat_interval_ms: u64 = 250;

pub const SnapshotComponent = struct {
    name: []const u8,
    blob: []const u8,
};

pub const ParseError = error{
    BadHostPort,
    BadPort,
};

/// Stubbed error sets — no real network errors surface in this build.
pub const ConnectError = error{PreviewDisabled} || ParseError;
pub const WriteError = error{ PreviewDisabled, OutOfMemory };
pub const PollError = error{ PreviewDisabled, OutOfMemory };

// ── Preview struct: stub ──────────────────────────────────────────

/// All network/IO plumbing has been stripped; methods return
/// `error.PreviewDisabled`. The public method shape is unchanged so
/// callers compile.
pub const Preview = struct {
    arena: std.heap.ArenaAllocator = undefined,
    last_heartbeat_ms: u64 = 0,

    pub fn connect(parent_alloc: std.mem.Allocator, host_port: []const u8) ConnectError!Preview {
        _ = parent_alloc;
        _ = host_port;
        return error.PreviewDisabled;
    }

    pub fn deinit(self: *Preview) void {
        _ = self;
    }

    pub fn sendHello(self: *Preview, engine_version: []const u8, pid: i32) WriteError!void {
        _ = self;
        _ = engine_version;
        _ = pid;
        return error.PreviewDisabled;
    }

    pub fn sendHeartbeat(self: *Preview, t_ms: u64) WriteError!void {
        _ = self;
        _ = t_ms;
        return error.PreviewDisabled;
    }

    pub fn tickHeartbeat(self: *Preview, now_ms: u64) WriteError!void {
        _ = self;
        _ = now_ms;
        return error.PreviewDisabled;
    }

    pub fn sendBye(self: *Preview, reason: ByeReason) WriteError!void {
        _ = self;
        _ = reason;
        return error.PreviewDisabled;
    }

    pub fn emitEntityCreated(
        self: *Preview,
        entity_id: u64,
        prefab_name: ?[]const u8,
    ) WriteError!void {
        _ = self;
        _ = entity_id;
        _ = prefab_name;
        return error.PreviewDisabled;
    }

    pub fn emitEntityDestroyed(self: *Preview, entity_id: u64) WriteError!void {
        _ = self;
        _ = entity_id;
        return error.PreviewDisabled;
    }

    pub fn emitComponentChanged(
        self: *Preview,
        entity_id: u64,
        comp_name: []const u8,
        comp_bytes: []const u8,
    ) WriteError!void {
        _ = self;
        _ = entity_id;
        _ = comp_name;
        _ = comp_bytes;
        return error.PreviewDisabled;
    }

    pub fn emitEntitySnapshot(
        self: *Preview,
        entity_id: u64,
        components: []const SnapshotComponent,
    ) WriteError!void {
        _ = self;
        _ = entity_id;
        _ = components;
        return error.PreviewDisabled;
    }

    pub fn emitNodeEntered(
        self: *Preview,
        flow_name: []const u8,
        node_id: u32,
    ) WriteError!void {
        _ = self;
        _ = flow_name;
        _ = node_id;
        return error.PreviewDisabled;
    }

    pub fn pollSubscription(self: *Preview) PollError!void {
        _ = self;
        return error.PreviewDisabled;
    }

    pub fn isComponentSubscribed(self: *const Preview, comp_name: []const u8) bool {
        _ = self;
        _ = comp_name;
        return false;
    }

    pub fn isFlowSubscribed(self: *const Preview, flow_name: []const u8) bool {
        _ = self;
        _ = flow_name;
        return false;
    }

    pub fn isEntityWatched(self: *const Preview, entity_id: u64) bool {
        _ = self;
        _ = entity_id;
        return false;
    }
};

/// Parse the `--preview-mode <host:port>` (or `--preview-mode=<host:port>`)
/// flag out of argv. Pure parsing, no network — kept intact.
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
