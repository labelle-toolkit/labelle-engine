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
///        {"kind":"frame_offer","shm_name":"/labelle-preview-<pid>","width":1280,"height":720,
///                  "format":"rgba8","ring_size":3,"slot_size_bytes":3686464}\n            (engine → editor, viewport)
///        {"kind":"frame_published","frame_idx":42,"produce_ns":12345}\n                   (engine → editor, viewport)
///        {"kind":"frame_accept"}\n                                                         (editor → engine, viewport)
///        {"kind":"frame_resize","width":1920,"height":1080}\n                              (editor → engine, viewport)
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
///
/// ## Structure (#preview split)
///
/// This file is a thin facade. The implementation is split across
/// `src/preview/` so no single file exceeds 1000 lines —
/// behavior-preserving, the public surface below is unchanged:
///
///   - `preview/protocol.zig`     — wire constants / message types /
///                                  error sets / `parseArgs`.
///   - `preview/socket.zig`       — platform socket I/O shims (#551).
///   - `preview/connection.zig`   — the `Preview` struct: lifecycle,
///                                  input queue, accessors, `writeFrame`.
///   - `preview/frame_stream.zig` — PIE viewport SHM/IOSurface producer.
///   - `preview/telemetry.zig`    — binary telemetry frames +
///                                  subscription poll.
const builtin = @import("builtin");

const protocol = @import("preview/protocol.zig");
const connection = @import("preview/connection.zig");

// ── Producer-side SHM / IOSurface modules (re-exported for tests +
//    downstream consumers; previously direct `@import`s here). ─────
pub const preview_shm = protocol.preview_shm;
pub const preview_iosurface = protocol.preview_iosurface;

// ── Protocol constants + wire-format types ──────────────────────────
pub const ByeReason = protocol.ByeReason;
pub const protocol_version = protocol.protocol_version;
pub const binary_magic = protocol.binary_magic;
pub const BinaryFrameKind = protocol.BinaryFrameKind;
pub const heartbeat_interval_ms = protocol.heartbeat_interval_ms;
pub const InputEvent = protocol.InputEvent;
pub const SnapshotComponent = protocol.SnapshotComponent;
pub const FramePixelFormat = protocol.FramePixelFormat;
pub const FrameOffer = protocol.FrameOffer;
pub const FrameHandshakeState = protocol.FrameHandshakeState;
pub const PendingResize = protocol.PendingResize;

// ── Error sets ──────────────────────────────────────────────────────
pub const ParseError = protocol.ParseError;
pub const ConnectError = protocol.ConnectError;
pub const WriteError = protocol.WriteError;
pub const PollError = protocol.PollError;

// ── The connect-out control channel ─────────────────────────────────
pub const Preview = connection.Preview;

// ── Argv helper for the assembler-generated `main.zig` ──────────────
pub const parseArgs = protocol.parseArgs;

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
