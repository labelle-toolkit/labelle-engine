//! macOS IOSurface-backed pixel ring producer for the PIE viewport
//! (#547 — Phase 2 zero-copy fast path, engine side).
//!
//! Pair to the consumer that already shipped in labelle-gui#115 (see
//! `labelle-gui/src/iosurface.zig` for the canonical protocol). The
//! engine allocates N `IOSurfaceRef` objects up front, stamps their
//! `IOSurfaceID`s into a `ControlBlock` written into slot 0 of the
//! existing `preview_shm.Producer` ring, and per frame just locks the
//! next surface, writes BGRA8 pixels, unlocks, and bumps the
//! shm header's `latest` slot pointer.
//!
//! Producer surface mirrors `preview_shm.Producer`:
//!
//!     init(name, opts) → Producer
//!     deinit()
//!     pixelsPtr() → Locked          // pointer + bytes_per_row + slot
//!     publish(stamp_now)
//!
//! Cross-process visibility:
//!   We set `kIOSurfaceIsGlobal = true` so the editor side can call
//!   `IOSurfaceLookup(id)` directly. Deprecated since 10.11 but still
//!   functional and what the labelle-gui consumer expects. Mach-port
//!   hand-off is the production path (separate ticket) — SCM_RIGHTS
//!   won't carry mach ports.
//!
//! Pixel format: BGRA8. The producer writes BGRA (the GL readback is
//! RGBA so a per-pixel swizzle happens inside `publish`). The eventual
//! render-to-IOSurface FBO path would dodge the swizzle entirely;
//! it's called out as a stretch goal in the ticket and deferred here.
//!
//! macOS-only by construction. Every entry point gates on
//! `builtin.os.tag == .macos`; on other platforms the public APIs
//! surface `error.PlatformUnsupported`. The control plane reuses
//! `preview_shm.Producer` verbatim so the editor-side polling /
//! shutdown signalling stay identical.

const std = @import("std");
const builtin = @import("builtin");
const shm = @import("preview_shm.zig");

pub const Error = error{
    PlatformUnsupported,
    RingSizeOutOfRange,
    IOSurfaceCreateFailed,
    IOSurfaceLockFailed,
    IOSurfaceUnlockFailed,
    IOSurfaceBaseAddressNull,
    AlreadyLocked,
    NotLocked,
    InvalidFrameSize,
    /// CoreFoundation allocator returned null — `CFNumberCreate` or
    /// `CFDictionaryCreateMutable` failed (typically under memory
    /// pressure). Surfacing as a distinct variant rather than
    /// OutOfMemory keeps the source of the failure obvious in logs.
    CFAllocationFailed,
} || shm.Error;

// ── CoreFoundation / IOSurface externs ─────────────────────────────
//
// These are macOS-only. The non-macOS build path never references
// them at link time because every public entry point returns
// `error.PlatformUnsupported` before reaching them.

pub const IOSurfaceRef = ?*opaque {};
pub const CFTypeRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFNumberRef = ?*anyopaque;
pub const CFDictionaryRef = ?*anyopaque;
pub const CFMutableDictionaryRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;

pub const IOSurfaceID = u32;
pub const IOReturn = c_int;
pub const MachPort = u32;

/// 'BGRA' four-CC — matches the consumer's `kPixelFormat_BGRA8` in
/// `labelle-gui/src/iosurface.zig`. MUST match exactly; bumping is a
/// protocol break.
pub const kPixelFormat_BGRA8: u32 = 0x42475241;

pub const kIOSurfaceLockReadOnly: u32 = 0x1;
pub const kIOSurfaceLockAvoidSync: u32 = 0x2;

pub const kCFNumberSInt32Type: c_int = 3;

/// Maximum ring size — matches consumer's `MAX_RING`. Bumping is a
/// protocol break with the editor.
pub const MAX_RING: u32 = 8;

// macOS-only externs. Linking these on Linux/Windows would fail; the
// gate is at every call site.
const macos = builtin.os.tag == .macos;

pub extern "c" fn IOSurfaceCreate(properties: CFDictionaryRef) IOSurfaceRef;
pub extern "c" fn IOSurfaceGetID(buffer: IOSurfaceRef) IOSurfaceID;
pub extern "c" fn IOSurfaceLock(buffer: IOSurfaceRef, options: u32, seed: ?*u32) IOReturn;
pub extern "c" fn IOSurfaceUnlock(buffer: IOSurfaceRef, options: u32, seed: ?*u32) IOReturn;
pub extern "c" fn IOSurfaceGetBaseAddress(buffer: IOSurfaceRef) ?*anyopaque;
pub extern "c" fn IOSurfaceGetWidth(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetHeight(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetBytesPerRow(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetAllocSize(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetSeed(buffer: IOSurfaceRef) u32;

pub extern "c" const kIOSurfaceWidth: CFStringRef;
pub extern "c" const kIOSurfaceHeight: CFStringRef;
pub extern "c" const kIOSurfaceBytesPerElement: CFStringRef;
pub extern "c" const kIOSurfaceBytesPerRow: CFStringRef;
pub extern "c" const kIOSurfacePixelFormat: CFStringRef;
/// Deprecated since 10.11 but functional. Required for the shortcut
/// where the consumer calls `IOSurfaceLookup(id)` directly across
/// processes. Drop once the mach-port path lands (separate ticket).
pub extern "c" const kIOSurfaceIsGlobal: CFStringRef;

pub extern "c" const kCFAllocatorDefault: CFAllocatorRef;
pub extern "c" const kCFTypeDictionaryKeyCallBacks: *const anyopaque;
pub extern "c" const kCFTypeDictionaryValueCallBacks: *const anyopaque;
pub extern "c" const kCFBooleanTrue: CFTypeRef;
pub extern "c" const kCFBooleanFalse: CFTypeRef;

pub extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    the_type: c_int,
    value_ptr: *const anyopaque,
) CFNumberRef;
pub extern "c" fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: isize,
    key_callbacks: *const anyopaque,
    value_callbacks: *const anyopaque,
) CFMutableDictionaryRef;
pub extern "c" fn CFDictionarySetValue(
    dict: CFMutableDictionaryRef,
    key: ?*const anyopaque,
    value: ?*const anyopaque,
) void;
pub extern "c" fn CFRelease(cf: CFTypeRef) void;

// ── Control-plane payload (rides inside slot 0 of the shm region) ──

/// Header written into the *first* shm slot's pixel area. The producer
/// initialises it exactly once at startup; the consumer reads it once
/// at startup; from then on only `Header.latest` is touched per frame.
///
/// Layout MUST match `labelle-gui/src/iosurface.zig:ControlBlock`. The
/// `MAGIC` constant ('IOSRFCL1') is shared verbatim.
pub const ControlBlock = extern struct {
    magic: u64,
    ring_size: u32,
    pixel_format: u32,
    width: u32,
    height: u32,
    ids: [MAX_RING]IOSurfaceID,
    _pad: [16]u8 = [_]u8{0} ** 16,

    /// 'IOSRFCL1' — same value as the consumer (`labelle-gui#115`).
    /// Bumping is a protocol break; coordinate with labelle-gui.
    pub const MAGIC: u64 = 0x494F535246434C31;
};

comptime {
    std.debug.assert(@sizeOf(ControlBlock) == 24 + MAX_RING * 4 + 16);
}

// ── BGRA8 property dict (macOS only) ───────────────────────────────

fn cfNumberU32(v: u32) Error!CFNumberRef {
    if (!macos) unreachable;
    const sv: i32 = @bitCast(v);
    const n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &sv);
    if (n == null) return error.CFAllocationFailed;
    return n;
}

/// Build a BGRA8 property dict with `kIOSurfaceIsGlobal = true`.
/// Returned dict is retained; caller must `CFRelease`.
///
/// Note: we pass `width*4` as the requested `kIOSurfaceBytesPerRow`
/// but the kernel may pad up for alignment — always query
/// `IOSurfaceGetBytesPerRow` after creation rather than assuming
/// `width * 4` (PoC bit us with this; see ticket macOS specifics).
pub fn makeBGRA8Properties(width: u32, height: u32) Error!CFDictionaryRef {
    if (!macos) unreachable;
    const dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks,
    );
    if (dict == null) return error.CFAllocationFailed;
    errdefer CFRelease(dict);

    // Build each CFNumber with its own errdefer so a partial failure
    // mid-list doesn't leak earlier ones. errdefers run LIFO so we
    // release the most-recent first — matching the manual CFRelease
    // chain at the end of the happy path.
    const w = try cfNumberU32(width);
    errdefer CFRelease(w);
    const h = try cfNumberU32(height);
    errdefer CFRelease(h);
    const bpe = try cfNumberU32(4);
    errdefer CFRelease(bpe);
    const bpr = try cfNumberU32(width * 4);
    errdefer CFRelease(bpr);
    const fmt = try cfNumberU32(kPixelFormat_BGRA8);
    errdefer CFRelease(fmt);

    CFDictionarySetValue(dict, kIOSurfaceWidth, w);
    CFDictionarySetValue(dict, kIOSurfaceHeight, h);
    CFDictionarySetValue(dict, kIOSurfaceBytesPerElement, bpe);
    CFDictionarySetValue(dict, kIOSurfaceBytesPerRow, bpr);
    CFDictionarySetValue(dict, kIOSurfacePixelFormat, fmt);
    // Required for cross-process IOSurfaceLookup without a mach-port
    // hand-off. Deprecated, still functional. TODO: replace with
    // mach-port path (separate ticket).
    CFDictionarySetValue(dict, kIOSurfaceIsGlobal, kCFBooleanTrue);
    CFRelease(w);
    CFRelease(h);
    CFRelease(bpe);
    CFRelease(bpr);
    CFRelease(fmt);
    return dict;
}

// ── RGBA → BGRA swizzle (producer side) ────────────────────────────

/// Swizzle a buffer in place from RGBA8 (GL readback order) to BGRA8
/// (what `CGLTexImageIOSurface2D` and `kPixelFormat_BGRA8` want).
/// The slice length must be a multiple of 4 — caller already validates
/// against the negotiated width*height*4.
///
/// In-place is intentional: the caller hands us a buffer it owns; we
/// rewrite it before the memcpy into the IOSurface. The eventual
/// render-to-IOSurface FBO path (stretch goal, deferred) would skip
/// this entirely.
pub fn swizzleRgbaToBgraInPlace(buf: []u8) void {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 4) {
        const r = buf[i];
        const b = buf[i + 2];
        buf[i] = b;
        buf[i + 2] = r;
        // G (i+1) and A (i+3) stay.
    }
}

/// Same swizzle, but copies from `src` into `dst` while reordering.
/// Used when the producer can't mutate the caller's buffer (e.g. it
/// belongs to a backend's PBO mapping). `dst.len == src.len` and both
/// must be a multiple of 4.
pub fn copySwizzleRgbaToBgra(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        dst[i] = src[i + 2]; // B
        dst[i + 1] = src[i + 1]; // G
        dst[i + 2] = src[i]; // R
        dst[i + 3] = src[i + 3]; // A
    }
}

// ── Producer ───────────────────────────────────────────────────────

pub const Options = struct {
    width: u32,
    height: u32,
    /// 2 or 3 typically — 3 buys jitter tolerance for the editor's
    /// upload cadence. Bounded by `MAX_RING`.
    ring_size: u32 = 3,
};

pub const Locked = struct {
    /// BGRA8 base pointer for the locked slot. Writers MUST honour
    /// `bytes_per_row` (the kernel may pad past `width * 4`).
    base: [*]u8,
    bytes_per_row: u32,
    slot: u32,
};

pub const Producer = struct {
    /// Control-plane shm ring. We hold a full `preview_shm.Producer`
    /// because we still use `header.latest`, `header.frame_count`,
    /// and the per-slot trailer (for the produce_ns stamp).
    shm_producer: shm.Producer,
    /// Ring of IOSurface refs we own. Held for the session — if we
    /// drop these the consumer's `IOSurfaceLookup` would start
    /// returning null.
    surfaces: [MAX_RING]IOSurfaceRef = [_]IOSurfaceRef{null} ** MAX_RING,
    ring_size: u32,
    width: u32,
    height: u32,
    /// Query-cached at init — IOSurface row stride is platform-
    /// controlled, NOT `width * 4`. Same value across all surfaces in
    /// the ring (they share dims/format).
    bytes_per_row: u32,
    /// Slot index the next `pixelsPtr`/`publish` pair will touch.
    /// Rotates 0..ring_size-1.
    next_slot: u32 = 0,
    /// Lock held between `pixelsPtr` and `publish` so the caller can
    /// write straight into `IOSurfaceGetBaseAddress`. `null` between
    /// publish cycles.
    locked_slot: ?u32 = null,

    /// Create the IOSurface ring, allocate the control-plane shm
    /// region, and stamp the `ControlBlock` into slot 0. Caller then
    /// calls `pixelsPtr` to lock a slot, writes BGRA8 pixels, and
    /// `publish` to advance `latest` + bump `frame_count`.
    pub fn init(name: [:0]const u8, opts: Options) Error!Producer {
        if (!macos) return error.PlatformUnsupported;
        if (opts.ring_size == 0 or opts.ring_size > MAX_RING) {
            return error.RingSizeOutOfRange;
        }

        var surfaces: [MAX_RING]IOSurfaceRef = [_]IOSurfaceRef{null} ** MAX_RING;
        var created: u32 = 0;
        errdefer {
            var i: u32 = 0;
            while (i < created) : (i += 1) {
                if (surfaces[i]) |s| CFRelease(@ptrCast(s));
            }
        }

        // One property dict reused for every surface — all N share
        // dims/format.
        const props = try makeBGRA8Properties(opts.width, opts.height);
        defer CFRelease(props);

        while (created < opts.ring_size) : (created += 1) {
            const ref = IOSurfaceCreate(props) orelse return error.IOSurfaceCreateFailed;
            surfaces[created] = ref;
        }

        // Initialise the control-plane shm region. We reuse
        // `preview_shm.Producer` verbatim — slot 0's pixel area is
        // where we stash the ControlBlock.
        var sp = try shm.Producer.init(name, .{
            .width = opts.width,
            .height = opts.height,
            .ring_size = opts.ring_size,
        });
        errdefer sp.deinit();

        // Stamp the ControlBlock into slot 0's pixel area. Written
        // exactly once; the consumer reads it exactly once.
        const ctrl: *ControlBlock = @ptrCast(@alignCast(sp.base + @sizeOf(shm.Header)));
        ctrl.* = .{
            .magic = 0,
            .ring_size = opts.ring_size,
            .pixel_format = kPixelFormat_BGRA8,
            .width = opts.width,
            .height = opts.height,
            .ids = [_]IOSurfaceID{0} ** MAX_RING,
        };
        var i: u32 = 0;
        while (i < opts.ring_size) : (i += 1) {
            ctrl.ids[i] = IOSurfaceGetID(surfaces[i]);
        }
        // Release-store the magic last so the consumer's acquire-load
        // sees a fully-populated ControlBlock (matches the PoC and
        // labelle-gui consumer expectations).
        @atomicStore(u64, &ctrl.magic, ControlBlock.MAGIC, .release);

        // Query bytes_per_row from the first surface — Apple may pad
        // past `width * 4` for alignment (ticket gotcha).
        const bpr: u32 = @intCast(IOSurfaceGetBytesPerRow(surfaces[0]));

        return .{
            .shm_producer = sp,
            .surfaces = surfaces,
            .ring_size = opts.ring_size,
            .width = opts.width,
            .height = opts.height,
            .bytes_per_row = bpr,
        };
    }

    pub fn deinit(self: *Producer) void {
        if (!macos) return;
        // Best-effort unlock if caller bailed mid-write.
        if (self.locked_slot) |slot| {
            if (self.surfaces[slot]) |s| {
                _ = IOSurfaceUnlock(s, 0, null);
            }
            self.locked_slot = null;
        }
        var i: u32 = 0;
        while (i < self.ring_size) : (i += 1) {
            if (self.surfaces[i]) |s| CFRelease(@ptrCast(s));
            self.surfaces[i] = null;
        }
        self.shm_producer.deinit();
    }

    /// Lock the next slot for write. Caller writes BGRA8 pixels into
    /// `Locked.base` honouring `Locked.bytes_per_row`, then calls
    /// `publish`.
    pub fn pixelsPtr(self: *Producer) Error!Locked {
        if (!macos) return error.PlatformUnsupported;
        if (self.locked_slot != null) return error.AlreadyLocked;
        const slot = self.next_slot;
        const surf = self.surfaces[slot];
        const lr = IOSurfaceLock(surf, 0, null);
        if (lr != 0) return error.IOSurfaceLockFailed;
        const base_opt = IOSurfaceGetBaseAddress(surf);
        const base: [*]u8 = @ptrCast(base_opt orelse {
            _ = IOSurfaceUnlock(surf, 0, null);
            return error.IOSurfaceBaseAddressNull;
        });
        self.locked_slot = slot;
        return .{ .base = base, .bytes_per_row = self.bytes_per_row, .slot = slot };
    }

    /// Unlock the current slot and publish its index via the shm
    /// header. Mirrors `preview_shm.Producer.publish` for the
    /// timestamp + frame-count release-store dance.
    pub fn publish(self: *Producer, stamp_now: bool) Error!void {
        if (!macos) return error.PlatformUnsupported;
        const slot = self.locked_slot orelse return error.NotLocked;
        const ul = IOSurfaceUnlock(self.surfaces[slot], 0, null);
        if (ul != 0) return error.IOSurfaceUnlockFailed;
        self.locked_slot = null;

        // Stamp the trailer in the matching shm slot — purely
        // metadata (frame_idx, produce_ns); pixel bytes in the shm
        // slot are unused in iosurface mode (they hold the
        // ControlBlock in slot 0 and are scratch in the others).
        self.shm_producer.next_slot = slot;
        self.shm_producer.publish(stamp_now);
        self.next_slot = (slot + 1) % self.ring_size;
    }

    /// Direct accessor for the IOSurface refs (intentional for
    /// future render-to-IOSurface FBO paths — defer for now). The
    /// returned ref is borrowed; do NOT `CFRelease` it.
    pub fn surfaceAt(self: *const Producer, slot: u32) IOSurfaceRef {
        if (slot >= self.ring_size) return null;
        return self.surfaces[slot];
    }

    /// Pass-through to the embedded shm header for shutdown signalling.
    pub fn header(self: *Producer) *shm.Header {
        return self.shm_producer.header;
    }
};

// ── Tests ──────────────────────────────────────────────────────────
//
// Most coverage lives in `test/preview_iosurface_test.zig` (per the
// engine's `test/*.zig is its own binary` convention). Keep only
// platform-agnostic, allocation-free static checks here.

test "ControlBlock layout matches consumer canonical" {
    // Mirrors `labelle-gui/src/iosurface.zig`'s compile-time assertion.
    // Drift in either file is a protocol break.
    try std.testing.expectEqual(@as(usize, 24 + MAX_RING * 4 + 16), @sizeOf(ControlBlock));
}

test "MAX_RING matches consumer" {
    // If this fails, labelle-gui#115's `MAX_RING` has drifted out of
    // sync with ours — coordinate before merging.
    try std.testing.expectEqual(@as(u32, 8), MAX_RING);
}

test "kPixelFormat_BGRA8 matches consumer four-CC" {
    // 'BGRA' as bytes in memory.
    try std.testing.expectEqual(@as(u32, 0x42475241), kPixelFormat_BGRA8);
}

test "ControlBlock.MAGIC matches consumer ('IOSRFCL1')" {
    try std.testing.expectEqual(@as(u64, 0x494F535246434C31), ControlBlock.MAGIC);
}

test "swizzleRgbaToBgraInPlace reorders channels correctly" {
    var buf: [8]u8 = .{
        0xAA, 0xBB, 0xCC, 0xDD,
        0x11, 0x22, 0x33, 0x44,
    };
    swizzleRgbaToBgraInPlace(&buf);
    // First pixel: R=AA G=BB B=CC A=DD → B=CC G=BB R=AA A=DD
    try std.testing.expectEqual(@as(u8, 0xCC), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xDD), buf[3]);
    // Second pixel.
    try std.testing.expectEqual(@as(u8, 0x33), buf[4]);
    try std.testing.expectEqual(@as(u8, 0x22), buf[5]);
    try std.testing.expectEqual(@as(u8, 0x11), buf[6]);
    try std.testing.expectEqual(@as(u8, 0x44), buf[7]);
}

test "copySwizzleRgbaToBgra reorders channels correctly" {
    const src: [4]u8 = .{ 0x10, 0x20, 0x30, 0x40 };
    var dst: [4]u8 = undefined;
    copySwizzleRgbaToBgra(&dst, &src);
    try std.testing.expectEqual(@as(u8, 0x30), dst[0]); // B
    try std.testing.expectEqual(@as(u8, 0x20), dst[1]); // G
    try std.testing.expectEqual(@as(u8, 0x10), dst[2]); // R
    try std.testing.expectEqual(@as(u8, 0x40), dst[3]); // A
}
