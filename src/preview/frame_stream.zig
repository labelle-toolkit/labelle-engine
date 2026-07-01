//! PIE viewport frame-stream producer logic (#543/#544/#547).
//!
//! Free functions operating on `*Preview` — the public methods on the
//! `Preview` struct (in `connection.zig`) are thin wrappers that
//! delegate here. Split out of `preview_mode.zig` verbatim;
//! behavior-preserving.
//!
//! Two mutually-exclusive producer modes share one `Preview`:
//!  - SHM ring (`begin/publish/endFrameStream`)
//!  - macOS IOSurface ring (`begin/publish/end FrameStreamIOSurface`,
//!    plus the Path-A `getIOSurfaceAt`/`signalSlotReady` pair)

const std = @import("std");
const builtin = @import("builtin");

const protocol = @import("protocol.zig");
const connection = @import("connection.zig");

const Preview = connection.Preview;
const FrameOffer = protocol.FrameOffer;
const WriteError = protocol.WriteError;
const PublishError = protocol.PublishError;
const preview_shm = protocol.preview_shm;
const preview_iosurface = protocol.preview_iosurface;

/// Process-wide monotonic suffix for SHM names. Each
/// `beginFrameStream` call increments this; combined with the PID
/// it keeps concurrent previews (e.g. test loopback fixtures and a
/// real game running in parallel) from colliding on the shm_open
/// namespace.
var next_stream_id: u32 = 0;

/// Offer the editor a SHM pixel ring. Call once the producer has
/// bound the region; transitions `frame_state` to `.offered`.
/// The producer should withhold any `frame_published` notifications
/// until the editor responds with `frame_accept`.
pub fn sendFrameOffer(self: *Preview, offer: FrameOffer) WriteError!void {
    const Msg = struct {
        kind: []const u8 = "frame_offer",
        shm_name: []const u8,
        width: u32,
        height: u32,
        format: []const u8,
        ring_size: u32,
        slot_size_bytes: u64,
    };
    try self.writeFrame(Msg{
        .shm_name = offer.shm_name,
        .width = offer.width,
        .height = offer.height,
        .format = offer.format.asString(),
        .ring_size = offer.ring_size,
        .slot_size_bytes = offer.slot_size_bytes,
    });
    self.frame_state = .offered;
}

/// Optional sidecar to wake the editor on a new frame. The wire
/// contract is "editor polls `Header.latest` to find the freshest
/// slot" — this frame is informational (and useful for editors that
/// want to throttle frame uploads to actual publishes rather than
/// every render tick). Cheap when the editor doesn't care: a
/// roughly 60-byte JSON line per produced frame.
pub fn sendFramePublished(self: *Preview, frame_idx: u64, produce_ns: u64) WriteError!void {
    const Msg = struct {
        kind: []const u8 = "frame_published",
        frame_idx: u64,
        produce_ns: u64,
    };
    try self.writeFrame(Msg{ .frame_idx = frame_idx, .produce_ns = produce_ns });
}

// ── #544: PBO/SHM publish (producer side) ──────────────────────────

/// Allocate a SHM ring sized for `width x height` RGBA8 frames and
/// emit a `frame_offer` over the control channel.
///
/// Caller (typically the backend's render-loop init code) calls
/// this once preview is connected and after the first render
/// surface dimensions are known. The producer state transitions
/// to `.offered`; subsequent `publishFrame` calls are gated on
/// the editor's `frame_accept` lifting state to `.accepted` (see
/// `isFrameAccepted`).
///
/// SHM name is derived from PID and a monotonic counter so concurrent
/// previews (e.g. unit-test loopback fixtures) don't collide. The
/// name is bounded at ~31 chars to satisfy macOS' PSHMNAMLEN.
pub fn beginFrameStream(
    self: *Preview,
    width: u32,
    height: u32,
) PublishError!void {
    // Reject if the iosurface mode is already active on this
    // `Preview`. The two modes are mutually exclusive — the
    // editor's `frame_offer` carries a single format, and
    // multiplexing them would force the editor's consumer to
    // pick a side mid-stream. The caller is expected to call
    // `endFrameStreamIOSurface` before switching modes (#547).
    if (self.frame_iosurface_producer != null) return error.WrongFrameMode;

    // Tear down any prior ring so a resize-driven re-offer is
    // idempotent — the protocol allows multiple frame_offer cycles
    // over the same connection.
    //
    // Reset `frame_state` *before* allocating the new ring so a
    // failure in `Producer.init` / `sendFrameOffer` leaves us in a
    // clean `.not_offered` state, not stuck at `.accepted` with a
    // null producer. (#546 review: backends gating on
    // `isFrameAccepted` would otherwise run their expensive PBO
    // readback only to fail at `publishFrame` with
    // `StreamNotActive`.) On success, `sendFrameOffer` below
    // lifts us back to `.offered`.
    if (self.frame_producer) |*p| {
        p.deinit();
        self.frame_producer = null;
    }
    if (self.frame_shm_name) |old| {
        self.inbox_alloc.free(old);
        self.frame_shm_name = null;
    }
    self.frame_state = .not_offered;
    self.frame_index = 0;

    // Heap-owned name (PID + counter, ≤ PSHMNAMLEN). Freed in
    // `endFrameStream` / the next `beginFrameStream` teardown /
    // `deinit`. See `allocShmName` for the format + rationale.
    const name_owned = try allocShmName(self);
    errdefer self.inbox_alloc.free(name_owned);

    const opts: preview_shm.Options = .{
        .width = width,
        .height = height,
        .ring_size = 3,
    };
    var producer = try preview_shm.Producer.init(name_owned, opts);
    errdefer producer.deinit();

    try sendFrameOffer(self, .{
        .shm_name = name_owned,
        .width = width,
        .height = height,
        .format = .rgba8,
        .ring_size = opts.ring_size,
        .slot_size_bytes = preview_shm.slotSize(width, height),
    });

    self.frame_producer = producer;
    self.frame_shm_name = name_owned;
}

/// Publish a CPU-side RGBA8 frame into the SHM ring and emit an
/// optional `frame_published` JSON sidecar.
///
/// `pixels` must be exactly `width * height * 4` bytes — the
/// dimensions agreed in `beginFrameStream` / the last accepted
/// `frame_offer`. Caller (typically the backend) is responsible
/// for the GPU → CPU readback (PBO async readback is the
/// recommended shape — see `imgui-preview-poc/src/game.zig`).
///
/// No-op (returns `error.StreamNotActive`) when the editor hasn't
/// yet acknowledged the offer (`frame_state != .accepted`). The
/// backend's render loop is expected to early-out via
/// `isFrameAccepted` to avoid the readback cost when no editor is
/// attached.
pub fn publishFrame(self: *Preview, pixels: []const u8) PublishError!void {
    const producer = if (self.frame_producer != null) &self.frame_producer.? else return error.StreamNotActive;
    if (!self.isFrameAccepted()) return error.StreamNotActive;

    const expected_len: usize = @intCast(@as(u64, producer.opts.width) * @as(u64, producer.opts.height) * 4);
    if (pixels.len != expected_len) return error.InvalidFrameSize;

    // Single memcpy into the next slot; stamp + publish.
    const slot_pixels = producer.pixelsPtr();
    @memcpy(slot_pixels[0..expected_len], pixels);
    producer.publish(true);

    self.frame_index +%= 1;
    // The control-channel sidecar is optional — emit best-effort
    // and swallow broken-pipe so an editor that drops mid-stream
    // doesn't tear down the render loop. The SHM publish above
    // is the authoritative signal; the editor can poll
    // `Header.latest` without seeing this frame.
    sendFramePublished(self, self.frame_index, preview_shm.nowNs()) catch {};
}

/// Tear down the SHM ring. Safe to call when no stream is active.
/// Does **not** send a `bye` — caller still owns that lifecycle.
pub fn endFrameStream(self: *Preview) void {
    if (self.frame_producer) |*p| {
        p.deinit();
        self.frame_producer = null;
    }
    if (self.frame_shm_name) |old| {
        self.inbox_alloc.free(old);
        self.frame_shm_name = null;
    }
    self.frame_state = .not_offered;
    self.frame_index = 0;
}

/// Allocate a per-process-unique SHM name for the next stream.
/// Format: `/lbl-prv-{pid_hex}-{stream_id_hex}` — 27 bytes max
/// (`/lbl-prv-` 9 + 8 hex + `-` 1 + 8 hex + NUL = 27), comfortably
/// under macOS' `PSHMNAMLEN` of 31. The **full** 32-bit PID
/// matters — truncating to 16 bits is small enough that two engine
/// processes whose PIDs share the low 16 bits collide on the same
/// name, and `Producer.init`'s pre-`shm_unlink` would then yank
/// each other's regions (#546 review). Concurrent calls from
/// different threads/Previews are race-free via an atomic RMW on
/// `next_stream_id`. Returns a heap-owned, NUL-terminated slice;
/// caller frees via `inbox_alloc.free` once the producer is
/// torn down (#549 — extracted from `beginFrameStream` and
/// `beginFrameStreamIOSurface` so PID-truncation-style fixes stay
/// in one place).
pub fn allocShmName(self: *Preview) error{OutOfMemory}![:0]u8 {
    // POSIX `getpid` returns pid_t (i32). On Windows `std.c.pid_t`
    // resolves to HANDLE (a pointer type) so the libc `getpid`
    // binding can't be reused; we go through kernel32's
    // `GetCurrentProcessId` (returns DWORD = u32). Either way the
    // shm-name fingerprint just needs 32 bits to disambiguate
    // per-process.
    const pid: u32 = if (builtin.os.tag == .windows)
        socket.getCurrentProcessId()
    else
        @bitCast(@as(i32, @intCast(std.c.getpid())));
    const stream_id = @atomicRmw(u32, &next_stream_id, .Add, 1, .monotonic) +% 1;
    // `std.fmt.allocPrintZ` was removed pre-0.16 — use the
    // explicit-sentinel form. `0` is `\0`.
    return std.fmt.allocPrintSentinel(self.inbox_alloc, "/lbl-prv-{x}-{x}", .{
        pid,
        stream_id,
    }, 0);
}

const socket = @import("socket.zig");

// ── #547: macOS IOSurface publish (producer side) ──────────────────

/// Allocate an IOSurface ring sized for `width x height` BGRA8
/// frames + the control-plane shm region, then emit a
/// `frame_offer` with `format = "iosurface_bgra8"`.
///
/// Mutually exclusive with `beginFrameStream` (SHM mode) on the
/// same `Preview` instance — see `PublishError.WrongFrameMode`.
///
/// macOS-only. On other platforms returns
/// `error.PlatformUnsupported` before allocating anything; the
/// caller (typically a backend's macOS-gated init path) is
/// expected to fall back to `beginFrameStream` everywhere else.
pub fn beginFrameStreamIOSurface(
    self: *Preview,
    width: u32,
    height: u32,
) PublishError!void {
    if (builtin.os.tag != .macos) return error.PlatformUnsupported;
    // Reject if SHM mode is already active. See the mirror guard
    // in `beginFrameStream`.
    if (self.frame_producer != null) return error.WrongFrameMode;

    // Tear down any prior iosurface ring so a resize-driven
    // re-offer cycle is idempotent. Reset state pre-allocation
    // so a failure in `Producer.init` / `sendFrameOffer` leaves
    // us cleanly at `.not_offered` (#546 review carries over to
    // this path verbatim).
    if (self.frame_iosurface_producer) |*p| {
        p.deinit();
        self.frame_iosurface_producer = null;
    }
    if (self.frame_shm_name) |old| {
        self.inbox_alloc.free(old);
        self.frame_shm_name = null;
    }
    self.frame_state = .not_offered;
    self.frame_index = 0;

    // Same per-process unique name shape as the SHM path —
    // shared via `allocShmName`, which advances the common
    // `next_stream_id` counter so SHM and iosurface allocations
    // within the same process never collide on the namespace.
    const name_owned = try allocShmName(self);
    errdefer self.inbox_alloc.free(name_owned);

    const opts: preview_iosurface.Options = .{
        .width = width,
        .height = height,
        .ring_size = 3,
    };
    var producer = try preview_iosurface.Producer.init(name_owned, opts);
    errdefer producer.deinit();

    try sendFrameOffer(self, .{
        .shm_name = name_owned,
        .width = width,
        .height = height,
        .format = .iosurface_bgra8,
        .ring_size = opts.ring_size,
        // `slot_size_bytes` describes the underlying shm slot
        // layout (the consumer uses it to walk to the trailer
        // for the produce_ns timestamp). The IOSurface pixel
        // bytes live elsewhere — the editor side already knows
        // to ignore the shm pixel area when format ==
        // `iosurface_bgra8` (see labelle-gui#115).
        .slot_size_bytes = preview_shm.slotSize(width, height),
    });

    self.frame_iosurface_producer = producer;
    self.frame_shm_name = name_owned;
}

/// Publish a CPU-side RGBA8 frame into the next IOSurface slot.
/// The producer-side swizzles into BGRA8 (the IOSurface pixel
/// format) while copying; the editor samples BGRA8 directly via
/// `CGLTexImageIOSurface2D` on a `GL_TEXTURE_RECTANGLE` (the
/// consumer side).
///
/// `pixels` is RGBA8 because that's what GL readback produces;
/// asking the caller to pre-swizzle would just push the same
/// per-byte work up the stack. The eventual render-to-IOSurface
/// FBO path would skip this and is the documented stretch goal
/// (deferred — separate ticket).
///
/// Length MUST be exactly `width * height * 4` — same shape as
/// `publishFrame`. The IOSurface's `bytes_per_row` may be padded
/// past `width * 4` (Apple alignment), so we copy row-by-row
/// rather than a single memcpy.
pub fn publishFrameIOSurface(self: *Preview, pixels: []const u8) PublishError!void {
    if (builtin.os.tag != .macos) return error.PlatformUnsupported;
    const producer = if (self.frame_iosurface_producer != null)
        &self.frame_iosurface_producer.?
    else
        return error.StreamNotActive;
    if (!self.isFrameAccepted()) return error.StreamNotActive;

    const expected_len: usize = @intCast(@as(u64, producer.width) * @as(u64, producer.height) * 4);
    if (pixels.len != expected_len) return error.InvalidFrameSize;

    const locked = try producer.pixelsPtr();
    // Row-by-row swizzle copy — `bytes_per_row` may exceed
    // `width * 4` on macOS due to alignment padding. The kernel
    // owns the per-row stride; we honour whatever it reported.
    const row_bytes: usize = producer.width * 4;
    var y: u32 = 0;
    while (y < producer.height) : (y += 1) {
        const src_row = pixels[y * row_bytes ..][0..row_bytes];
        const dst_row = locked.base[y * locked.bytes_per_row ..][0..row_bytes];
        preview_iosurface.copySwizzleRgbaToBgra(dst_row, src_row);
    }
    try producer.publish(true);

    self.frame_index +%= 1;
    // Optional sidecar — best-effort, same shape as the SHM
    // `publishFrame`. The IOSurface publish above is the
    // authoritative signal.
    sendFramePublished(self, self.frame_index, preview_shm.nowNs()) catch {};
}

/// Borrow the underlying `IOSurfaceRef` for slot N. Caller wraps
/// the surface as an `MTLTexture` (via
/// `MTLDevice.newTextureWithDescriptor:iosurface:plane:`), an
/// `IOSurface`-backed `CVPixelBuffer`, or any other API that
/// consumes IOSurfaces, then renders directly into it. The
/// returned ref is borrowed — do NOT `CFRelease` it; the producer
/// owns lifetime for the duration of the stream.
///
/// Slot indexing matches the `ControlBlock.ids[]` layout the
/// consumer side reads (so a producer that picks slot N here and
/// then calls `signalSlotReady(N)` lines up with the consumer's
/// `surfaces[N]` lookup verbatim). Stable for the lifetime of
/// `beginFrameStreamIOSurface` — `endFrameStreamIOSurface` /
/// `deinit` invalidate every slot's surface.
///
/// Returns `null` for an out-of-range slot, when the iosurface
/// stream is not active, or on non-macOS platforms (the producer
/// is macOS-only by construction). Pair with
/// `signalSlotReady` to publish a slot the caller rendered into.
pub fn getIOSurfaceAt(self: *const Preview, slot: u32) ?preview_iosurface.IOSurfaceRef {
    if (builtin.os.tag != .macos) return null;
    const p = if (self.frame_iosurface_producer) |*pp| pp else return null;
    // `surfaceAt` already returns null (the inner `?*opaque` null)
    // for out-of-range slots; collapse that into the outer
    // optional so callers get a single `null` regardless of the
    // failure shape (slot OOB vs. stream-not-active vs. wrong
    // platform). The `?IOSurfaceRef` ergonomics is purely for the
    // caller — `surfaceAt`'s `IOSurfaceRef` is already itself
    // optional and we'd otherwise force two layers of `if (… |s| …)`
    // at every Path-A call site.
    if (slot >= p.ring_size) return null;
    return p.surfaceAt(slot);
}

/// Signal the editor that slot N's IOSurface has freshly-rendered
/// content. This is the Path-A counterpart to `publishFrameIOSurface`:
/// the caller has already rendered into the IOSurface itself
/// (typically via an `MTLTexture` wrapper that uses the surface as
/// a render-target backing store), so we don't touch pixel memory.
/// We just stamp the shm slot's trailer + bump `header.latest` to
/// `slot`, advance `frame_index`, and emit a best-effort
/// `frame_published` JSON sidecar.
///
/// Equivalent to the publish half of `publishFrameIOSurface` minus
/// the lock / row-by-row swizzle copy. Same handshake gating —
/// returns `error.StreamNotActive` when the editor hasn't ACKed
/// the offer yet — and the same slot-bounds check as the SHM
/// publish path (`error.InvalidFrameSize` when
/// `slot >= ring_size`; the name keeps parity with the existing
/// `publishFrame` error vocabulary, even though no pixel
/// dimensions are involved).
pub fn signalSlotReady(self: *Preview, slot: u32) PublishError!void {
    if (builtin.os.tag != .macos) return error.PlatformUnsupported;
    const p = if (self.frame_iosurface_producer != null)
        &self.frame_iosurface_producer.?
    else
        return error.StreamNotActive;
    if (!self.isFrameAccepted()) return error.StreamNotActive;
    if (slot >= p.ring_size) return error.InvalidFrameSize;

    // Mirror the publish dance from `publishFrameIOSurface` without
    // the lock + swizzle copy. The IOSurface contents are already
    // current (the caller rendered into them via Metal); all we
    // owe the consumer is the slot-pointer bump + the trailer
    // stamp the shm-side reader expects to find.
    p.shm_producer.next_slot = slot;
    p.shm_producer.publish(true);
    p.next_slot = (slot + 1) % p.ring_size;

    self.frame_index +%= 1;
    sendFramePublished(self, self.frame_index, preview_shm.nowNs()) catch {};
}

/// Tear down the IOSurface ring + control-plane shm region.
/// Safe to call when no iosurface stream is active — no-ops in
/// that case. Critically, also a no-op when an SHM-mode stream
/// is active: that path's `frame_shm_name` is owned in parallel
/// by `beginFrameStream`'s producer (which holds a reference to
/// the same `[:0]u8`), so freeing it here would land a
/// use-after-free at the SHM producer's later `shm_unlink`.
/// Caller owns mode selection. Does NOT send a `bye` — caller
/// owns the connection lifecycle.
pub fn endFrameStreamIOSurface(self: *Preview) void {
    if (self.frame_iosurface_producer == null) return;
    var p = self.frame_iosurface_producer.?;
    p.deinit();
    self.frame_iosurface_producer = null;
    if (self.frame_shm_name) |old| {
        self.inbox_alloc.free(old);
        self.frame_shm_name = null;
    }
    self.frame_state = .not_offered;
    self.frame_index = 0;
}
