//! Preview-mode wire protocol: constants, message-shape types, and
//! the error sets shared across the connection helpers.
//!
//! Extracted from `preview_mode.zig` verbatim — behavior-preserving.
//! See `preview_mode.zig`'s top-of-file doc for the full protocol
//! description (JSON control plane + binary telemetry plane).

const std = @import("std");

pub const preview_shm = @import("../preview_shm.zig");
pub const preview_iosurface = @import("../preview_iosurface.zig");

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

/// Input event delivered from the editor's Game View tab to the
/// headless game (labelle-assembler#143). The editor captures mouse
/// activity over the IOSurface texture, converts to surface-space
/// coords, and ships these as JSON over the existing control channel.
/// The game's frame loop drains them via `popInputEvent` and forwards
/// to whatever input sink it has (sokol_imgui's `add_*_event` for the
/// imgui plugin; the engine's `backend_input` for game-side input).
pub const InputEvent = union(enum) {
    mouse_pos: struct { x: f32, y: f32 },
    mouse_button: struct { button: i32, down: bool },
};

pub const input_queue_capacity: usize = 256;

/// A (component_name, raw_bytes) pair for `emitEntitySnapshot`. Both
/// slices are borrowed — they only need to outlive the snapshot call.
pub const SnapshotComponent = struct {
    name: []const u8,
    bytes: []const u8,
};

// ── PIE viewport handshake (#543) ───────────────────────────────────

/// Pixel format identifiers carried over the wire. Plain enum to keep
/// the JSON-serializer side trivial. Add new entries when the producer
/// gains support; consumers compare by string.
///
/// `iosurface_bgra8` is the macOS zero-copy path (#547): the shm
/// region carries only a `ControlBlock` + `Header.latest` slot
/// pointer; the pixel bytes live in `IOSurfaceRef` objects whose IDs
/// the editor looks up via `IOSurfaceLookup`. The consumer side of
/// this lives in `labelle-gui/src/iosurface.zig`.
pub const FramePixelFormat = enum {
    rgba8,
    iosurface_bgra8,

    pub fn asString(self: FramePixelFormat) []const u8 {
        return switch (self) {
            .rgba8 => "rgba8",
            .iosurface_bgra8 => "iosurface_bgra8",
        };
    }
};

/// `frame_offer` payload. `shm_name` is the POSIX shm name (`/labelle-…`)
/// the engine has bound; the editor will `shm_open` it and map
/// `header_bytes + ring_size * slot_size_bytes`. All fields borrowed —
/// only need to outlive the `sendFrameOffer` call.
pub const FrameOffer = struct {
    shm_name: []const u8,
    width: u32,
    height: u32,
    format: FramePixelFormat = .rgba8,
    ring_size: u32 = 3,
    slot_size_bytes: u64,
};

/// Three-state handshake. Producer transitions:
///
///   not_offered  ── sendFrameOffer ──▶  offered
///   offered      ── (editor sends frame_accept) ──▶  accepted
///
/// A `frame_resize` from the editor does **not** kick us out of
/// `.accepted`; it just sets `pending_resize`. The caller decides
/// whether/when to honour it (typically: tear down the current ring,
/// send a new `frame_offer`, wait for `frame_accept` again).
pub const FrameHandshakeState = enum {
    not_offered,
    offered,
    accepted,
};

/// Pending resize requested by the editor. Producer polls
/// `Preview.takeResize` once per frame; nil result means no resize
/// requested since last poll.
pub const PendingResize = struct {
    width: u32,
    height: u32,
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

/// Errors specific to `beginFrameStream` / `publishFrame`.
/// Augments `WriteError` (control-channel write failure) with
/// the SHM-allocation failure modes from `preview_shm.Error`.
///
/// `StreamNotActive` and `InvalidFrameSize` are split on purpose
/// — the former is "no editor attached / not yet accepted /
/// stream torn down," the latter is "you handed me the wrong
/// number of pixel bytes for the negotiated dims." Conflating
/// them was the #546 review feedback.
///
/// `WrongFrameMode` (#547) is raised by `beginFrameStream` when
/// the iosurface mode is already active on the same `Preview`
/// (and vice versa). The two modes are mutually exclusive on a
/// single instance — the editor offer carries the format once
/// and the producer doesn't try to multiplex.
pub const PublishError = WriteError || preview_shm.Error ||
    preview_iosurface.Error || error{
    StreamNotActive,
    InvalidFrameSize,
    WrongFrameMode,
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
