//! Cross-process pixel ring backed by POSIX shared memory (macOS / Linux)
//! or Win32 file-mapping objects (Windows).
//!
//! Layout: a single mapped region containing
//!
//!     [ Header (cacheline-aligned) ]
//!     [ Slot 0 pixel bytes (stride * height) ]
//!     [ Slot 1 pixel bytes ... ]
//!     [ Slot N-1 pixel bytes ]
//!
//! The producer (engine) claims a slot, writes, and publishes the slot
//! index via `Header.latest`. The consumer (editor in labelle-gui)
//! reads `latest` (mailbox semantics — always grab the freshest, drop
//! older).
//!
//! Each slot also carries a monotonic `frame_idx` and a producer-stamped
//! `produce_ns` timestamp so the consumer can compute end-to-end latency.
//!
//! Validated end-to-end at 1280x720@60 with raw-IPC p50=5µs / p99=40µs
//! and zero drops in the matched-FPS bench (see imgui-preview-poc/
//! experiments/bench/ — both macOS native and aarch64 ubuntu Docker
//! came within 5% on throughput).
//!
//! Pairs with the PIE-viewport handshake (#543) and is driven from
//! `Preview.beginFrameStream` / `publishFrame` / `endFrameStream`
//! (this file is the implementation; that file is the protocol API).
//!
//! ## Windows port (#551)
//!
//! The on-the-wire layout and the `Header` / `SlotTrailer` ABI are
//! identical across platforms — only the alloc/map/free paths fork.
//! POSIX uses `shm_open` + `ftruncate` + `mmap`; Windows uses
//! `CreateFileMappingW` + `MapViewOfFile`. Naming:
//!
//!     POSIX:   /lbl-prv-<pid_hex>-<id_hex>
//!     Windows: Local\lbl-prv-<pid_hex>-<id_hex>
//!
//! Windows `Local\` namespace works for unprivileged processes within
//! a single user session — fine for an editor + game scenario. Using
//! `Global\` would require `SeCreateGlobalPrivilege` which the editor
//! generally doesn't have.
//!
//! `shm_unlink` doesn't exist on Windows; section objects are
//! reference-counted on the kernel handle and disappear when the last
//! handle closes (`CloseHandle`). We no-op the unlink there.

const std = @import("std");
const builtin = @import("builtin");

/// Bionic doesn't ship `shm_open` / `shm_unlink` — Android uses ashmem
/// instead. `libgame.so` would otherwise fail to `dlopen` at runtime
/// with `cannot locate symbol "shm_unlink"` on `NativeActivity.onCreate`.
/// The preview pipeline (POSIX shm producer/consumer) is editor-side
/// only — there is no in-process preview consumer on-device — so on
/// Android we return `error.ShmOpenFailed` from every entry point and
/// rely on Zig's comptime dead-code elimination to drop the linker
/// references to `std.c.shm_*` entirely.
const is_android_abi = builtin.target.abi == .android or builtin.target.abi == .androideabi;

pub const PIXEL_FORMAT_RGBA8: u32 = 0x52474241; // 'RGBA'
pub const MAGIC: u64 = 0x4C424C5052564653; // 'LBLPRVFS' — labelle preview frame stream
pub const PROTOCOL_VERSION: u32 = 1;

pub const Error = error{
    ShmOpenFailed,
    FtruncateFailed,
    MmapFailed,
    FstatFailed,
    BadMagic,
    BadVersion,
    TooSmall,
    /// Options failed `validateOptions` — zero / overflowing dims or
    /// `ring_size == 0`. Producer side only; the consumer mirrors the
    /// producer's header.
    InvalidOptions,
};

/// Cacheline-aligned header. Field layout is a stable ABI across the
/// two processes; do not reorder.
pub const Header = extern struct {
    magic: u64,
    version: u32,
    pixel_format: u32,
    width: u32,
    height: u32,
    stride: u32,
    ring_size: u32,
    /// Slot byte size, including any trailing padding to the next
    /// cacheline. `slot_offset(i) = header_size + i * slot_size`.
    slot_size: u64,
    /// Index of the most-recently published slot. Producer writes,
    /// consumer reads. Single-writer / single-reader; no atomics
    /// needed on the surface (writer fences with full memory barrier
    /// before publishing — see `Producer.publish`).
    latest: u32,
    /// Monotonic counter of frames published since the producer
    /// started. Used by the consumer to detect "new frame available."
    frame_count: u64,
    /// Set non-zero by either side when shutting down. The other
    /// side polls and exits its loop.
    shutdown: u32,
    /// Trailing pad so `@sizeOf(Header) == 64`. With the natural
    /// 8-byte alignment slop between `latest` and `frame_count`, the
    /// fields above end at byte 60 — so 4 bytes of explicit padding
    /// brings the struct to one cacheline.
    _pad: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) % 64 == 0);
}

/// Per-slot side-band: stamped by the producer when the slot is
/// published. The PoC stuffs this into the last few bytes of the slot
/// rather than carrying a separate trailer array, since the slot has
/// guaranteed padding (rounded up to cacheline).
pub const SlotTrailer = extern struct {
    frame_idx: u64,
    produce_ns: u64, // CLOCK_MONOTONIC nanoseconds at publish
    _pad: [48]u8,
};

comptime {
    std.debug.assert(@sizeOf(SlotTrailer) == 64);
}

pub const Options = struct {
    width: u32,
    height: u32,
    /// 2 or 3 — 2 is sufficient for single-writer / single-reader at
    /// 60 Hz; 3 buys a little jitter tolerance.
    ring_size: u32 = 3,
};

/// Path used for `shm_open` on POSIX (must start with `/` and be
/// ≤ `PSHMNAMLEN`, typically 31 chars on macOS). On Windows the
/// caller is expected to pass a `Local\…` or `Global\…` name; the
/// helpers below adapt the leading `/` automatically (see
/// `windowsMappingNameFromPosix`).
pub const default_name: [:0]const u8 = "/labelle-preview-default";

/// Upper bound on each dimension to keep `width * height * 4` from
/// overflowing `u64`. At 4 bytes/pixel a 16384×16384 buffer is 1 GiB,
/// already well past anything the editor would sanely display; the
/// hard cap is the `u32 stride = width * 4` headroom.
pub const max_dim: u32 = std.math.maxInt(u32) / 4;

/// Compute the slot size (pixel bytes + trailer, padded to cacheline).
/// Returns 0 if either dimension is out of range — callers gate on
/// `validateOptions` before using this.
pub fn slotSize(width: u32, height: u32) u64 {
    if (width == 0 or height == 0 or width > max_dim or height > max_dim) return 0;
    const raw: u64 = @as(u64, width) * @as(u64, height) * 4 + @sizeOf(SlotTrailer);
    return std.mem.alignForward(u64, raw, 64);
}

/// Reject malformed `Options` before we hand them to `shm_open` /
/// `ftruncate`. The producer surfaces these as `Error.InvalidOptions`.
pub fn validateOptions(opts: Options) bool {
    if (opts.ring_size == 0) return false;
    if (opts.width == 0 or opts.height == 0) return false;
    if (opts.width > max_dim or opts.height > max_dim) return false;
    return true;
}

pub fn totalSize(opts: Options) u64 {
    return @sizeOf(Header) + @as(u64, opts.ring_size) * slotSize(opts.width, opts.height);
}

/// Wall-clock monotonic nanoseconds — used for the latency stamp.
///
/// POSIX: `clock_gettime(CLOCK_MONOTONIC)`. On the vanishingly-rare
/// failure (per POSIX, EINVAL only — and CLOCK_MONOTONIC is mandatory)
/// we return `0` rather than reading uninitialized `timespec` memory.
/// A zero timestamp shows up as a giant negative latency on the editor
/// side, which is the right signal: "this frame's timing is unreliable"
/// (#546 review).
///
/// Windows: `QueryPerformanceCounter` + `QueryPerformanceFrequency`.
/// Both are documented infallible on Windows XP+ (return BOOL but
/// always succeed on supported platforms — same "return 0 on
/// theoretical failure" pattern).
pub fn nowNs() u64 {
    if (builtin.os.tag == .windows) {
        var freq: i64 = 0;
        var counter: i64 = 0;
        if (windows.QueryPerformanceFrequency(&freq) == 0) return 0;
        if (windows.QueryPerformanceCounter(&counter) == 0) return 0;
        if (freq <= 0) return 0;
        // ns = counter * 1e9 / freq, computed as (counter / freq) * 1e9 +
        // (counter % freq) * 1e9 / freq to avoid overflow on counter * 1e9.
        const c: u64 = @intCast(counter);
        const f: u64 = @intCast(freq);
        return (c / f) * std.time.ns_per_s + (c % f) * std.time.ns_per_s / f;
    } else {
        var ts: std.posix.timespec = undefined;
        if (std.posix.system.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        const sec: u64 = @intCast(ts.sec);
        const nsec: u64 = @intCast(ts.nsec);
        return sec * std.time.ns_per_s + nsec;
    }
}

// ── Platform-specific bindings ────────────────────────────────────

/// Backing handle for a mapped region. POSIX file descriptor on
/// macOS / Linux; Win32 section-object handle on Windows. Kept
/// in the public API only as the producer's / consumer's stored
/// field — callers don't touch it.
pub const Handle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.c.fd_t;

const windows = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;

    // Win32 file-mapping protection / access constants
    pub const PAGE_READWRITE: u32 = 0x04;
    pub const SECTION_QUERY: u32 = 0x0001;
    pub const SECTION_MAP_WRITE: u32 = 0x0002;
    pub const SECTION_MAP_READ: u32 = 0x0004;
    pub const FILE_MAP_READ: u32 = SECTION_MAP_READ;
    pub const FILE_MAP_WRITE: u32 = SECTION_MAP_WRITE;
    pub const FILE_MAP_ALL_ACCESS: u32 = 0xF001F;
    pub const INVALID_HANDLE_VALUE: win.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    pub extern "kernel32" fn CreateFileMappingW(
        hFile: win.HANDLE,
        lpAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?win.HANDLE;

    pub extern "kernel32" fn OpenFileMappingW(
        dwDesiredAccess: u32,
        bInheritHandle: i32,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?win.HANDLE;

    pub extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: win.HANDLE,
        dwDesiredAccess: u32,
        dwFileOffsetHigh: u32,
        dwFileOffsetLow: u32,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?*anyopaque;

    pub extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: *const anyopaque,
    ) callconv(.winapi) i32;

    pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    pub extern "kernel32" fn QueryPerformanceCounter(
        lpPerformanceCount: *i64,
    ) callconv(.winapi) i32;

    pub extern "kernel32" fn QueryPerformanceFrequency(
        lpFrequency: *i64,
    ) callconv(.winapi) i32;

    /// Convert a POSIX-style `/foo` shm name into a Win32 file-mapping
    /// name in the user-session namespace. We strip the leading `/`
    /// (Windows treats it as a path separator inside object names) and
    /// prefix `Local\`. The result is UTF-16 since `CreateFileMappingW`
    /// is the wide-char variant.
    ///
    /// Caller frees the returned slice with the same allocator.
    pub fn mappingNameFromPosix(alloc: std.mem.Allocator, posix_name: []const u8) ![:0]u16 {
        const stripped = if (posix_name.len > 0 and posix_name[0] == '/')
            posix_name[1..]
        else
            posix_name;
        // "Local\" prefix = 6 chars. Build the UTF-8 form first, then
        // convert to UTF-16 with a NUL terminator.
        var utf8 = std.array_list.Managed(u8).init(alloc);
        defer utf8.deinit();
        try utf8.appendSlice("Local\\");
        try utf8.appendSlice(stripped);
        return std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8.items);
    }
} else struct {};

// ── Cross-platform map / unmap helpers ─────────────────────────────

const MappedRegion = struct {
    base: [*]u8,
    total_size: usize,
    handle: Handle,
};

/// Create a new mapping (or open + resize an existing one on POSIX —
/// the producer's create-or-reattach idiom).
fn createMapping(name: [:0]const u8, total: u64) Error!MappedRegion {
    if (is_android_abi) {
        // See top-of-file note on Bionic. Preview pipeline isn't reachable on-device.
        return Error.ShmOpenFailed;
    } else if (builtin.os.tag == .windows) {
        // The producer side. CreateFileMappingW with hFile=INVALID_HANDLE_VALUE
        // creates a section backed by the system paging file (i.e. shared
        // memory). Same name → existing section is reopened with the same
        // permissions; on subsequent runs we map the existing region rather
        // than allocating a new one. The kernel handle is refcounted, so
        // "leftover from a crashed run" still works: once the original
        // process exits its handles are released and the section is
        // garbage-collected.
        //
        // Mapping name is wide-char + Local\ prefix per
        // `mappingNameFromPosix`. We allocate via the page allocator to
        // avoid threading an allocator through the function signature.
        const wname = windows.mappingNameFromPosix(std.heap.page_allocator, name) catch
            return Error.ShmOpenFailed;
        defer std.heap.page_allocator.free(wname);

        const size_high: u32 = @intCast(total >> 32);
        const size_low: u32 = @intCast(total & 0xFFFFFFFF);
        const hMap_opt = windows.CreateFileMappingW(
            windows.INVALID_HANDLE_VALUE,
            null,
            windows.PAGE_READWRITE,
            size_high,
            size_low,
            wname.ptr,
        );
        const hMap = hMap_opt orelse return Error.ShmOpenFailed;
        errdefer _ = std.os.windows.CloseHandle(hMap);

        const raw = windows.MapViewOfFile(
            hMap,
            windows.FILE_MAP_ALL_ACCESS,
            0,
            0,
            @intCast(total),
        ) orelse return Error.MmapFailed;

        return .{
            .base = @ptrCast(@alignCast(raw)),
            .total_size = @intCast(total),
            .handle = hMap,
        };
    } else {
        // Best-effort cleanup of any stale region from a previous run.
        // On macOS, `ftruncate` on a POSIX shm object only succeeds once
        // (at creation). A leftover from a crashed run will refuse to
        // resize and we'd fail with `FtruncateFailed`. `shm_unlink` is
        // the only safe escape hatch; if no stale region exists it's a
        // no-op (ENOENT) and we proceed to a fresh shm_open below.
        // On linux this is also harmless: shm_unlink + shm_open(CREAT)
        // gets us a fresh inode either way, matching prior behaviour.
        _ = std.c.shm_unlink(name.ptr);

        // O_RDWR | O_CREAT (no O_EXCL — reattach is fine).
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true };
        const flags_int: c_int = @bitCast(flags);
        const fd: std.c.fd_t = @intCast(std.c.shm_open(name.ptr, flags_int, @as(std.c.mode_t, 0o600)));
        if (fd < 0) return Error.ShmOpenFailed;
        errdefer _ = std.c.close(fd);

        // ftruncate always — handles both fresh-create and reattach-with-different-size.
        if (std.c.ftruncate(fd, @intCast(total)) != 0) {
            return Error.FtruncateFailed;
        }

        const prot: std.c.PROT = .{ .READ = true, .WRITE = true };
        const map_flags: std.c.MAP = .{ .TYPE = .SHARED };
        const raw = std.c.mmap(null, @intCast(total), prot, map_flags, fd, 0);
        if (raw == std.c.MAP_FAILED) return Error.MmapFailed;

        return .{
            .base = @ptrCast(@alignCast(raw)),
            .total_size = @intCast(total),
            .handle = fd,
        };
    }
}

/// Open an existing mapping (consumer side).
fn openMapping(name: [:0]const u8) Error!MappedRegion {
    if (is_android_abi) {
        return Error.ShmOpenFailed;
    } else if (builtin.os.tag == .windows) {
        const wname = windows.mappingNameFromPosix(std.heap.page_allocator, name) catch
            return Error.ShmOpenFailed;
        defer std.heap.page_allocator.free(wname);

        const hMap_opt = windows.OpenFileMappingW(
            windows.FILE_MAP_READ | windows.FILE_MAP_WRITE,
            0,
            wname.ptr,
        );
        const hMap = hMap_opt orelse return Error.ShmOpenFailed;
        errdefer _ = std.os.windows.CloseHandle(hMap);

        // First map the header alone to discover the total size, then
        // remap. `MapViewOfFile(hMap, ..., 0)` would map the whole
        // section, but we'd then have to `VirtualQuery` to discover its
        // actual extent — going through the header is shorter and uses
        // only well-supported APIs.
        const hdr_raw = windows.MapViewOfFile(
            hMap,
            windows.FILE_MAP_READ | windows.FILE_MAP_WRITE,
            0,
            0,
            @sizeOf(Header),
        ) orelse return Error.MmapFailed;
        const hdr_view: *Header = @ptrCast(@alignCast(hdr_raw));
        if (hdr_view.magic != MAGIC) {
            _ = windows.UnmapViewOfFile(hdr_raw);
            return Error.BadMagic;
        }
        if (hdr_view.version != PROTOCOL_VERSION) {
            _ = windows.UnmapViewOfFile(hdr_raw);
            return Error.BadVersion;
        }
        const total: u64 = @sizeOf(Header) + @as(u64, hdr_view.ring_size) * hdr_view.slot_size;
        if (total < @sizeOf(Header)) {
            _ = windows.UnmapViewOfFile(hdr_raw);
            return Error.TooSmall;
        }
        _ = windows.UnmapViewOfFile(hdr_raw);

        const raw = windows.MapViewOfFile(
            hMap,
            windows.FILE_MAP_READ | windows.FILE_MAP_WRITE,
            0,
            0,
            @intCast(total),
        ) orelse return Error.MmapFailed;
        return .{
            .base = @ptrCast(@alignCast(raw)),
            .total_size = @intCast(total),
            .handle = hMap,
        };
    } else {
        const flags: std.c.O = .{ .ACCMODE = .RDWR };
        const flags_int: c_int = @bitCast(flags);
        const fd: std.c.fd_t = @intCast(std.c.shm_open(name.ptr, flags_int, @as(std.c.mode_t, 0)));
        if (fd < 0) return Error.ShmOpenFailed;
        errdefer _ = std.c.close(fd);

        const size_bytes = try fdSize(fd);
        if (size_bytes < @sizeOf(Header)) return Error.TooSmall;
        const total: usize = @intCast(size_bytes);

        const prot: std.c.PROT = .{ .READ = true, .WRITE = true };
        const map_flags: std.c.MAP = .{ .TYPE = .SHARED };
        const raw = std.c.mmap(null, total, prot, map_flags, fd, 0);
        if (raw == std.c.MAP_FAILED) return Error.MmapFailed;
        return .{
            .base = @ptrCast(@alignCast(raw)),
            .total_size = total,
            .handle = fd,
        };
    }
}

fn unmapRegion(region: *const MappedRegion) void {
    if (builtin.os.tag == .windows) {
        _ = windows.UnmapViewOfFile(@ptrCast(region.base));
        _ = std.os.windows.CloseHandle(region.handle);
    } else {
        _ = std.c.munmap(@ptrCast(@alignCast(region.base)), region.total_size);
        _ = std.c.close(region.handle);
    }
}

/// Best-effort unlink (POSIX only — `shm_unlink` doesn't exist on
/// Windows where section objects are reference-counted on the handle).
fn unlinkName(name: [:0]const u8) void {
    if (is_android_abi) return;
    if (builtin.os.tag == .windows) return;
    _ = std.c.shm_unlink(name.ptr);
}

/// Cross-platform `fstat`-equivalent that just returns the file size in bytes.
///
/// macOS exposes `std.c.fstat` as a real libc binding; on Linux 0.16 the
/// `std.c.fstat` slot is `void` (the libc binding was removed in favour of
/// `statx`), so we route through the raw syscall there. The consumer only
/// needs the byte size to size its mmap, hence this narrow shim rather than
/// porting the full `Stat` struct. Windows takes a different path entirely
/// (the header carries enough information to size the view), so this helper
/// is POSIX-only.
fn fdSize(fd: std.c.fd_t) !u64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const empty: [*:0]const u8 = "";
        const mask: linux.STATX = .{ .SIZE = true };
        const rc = linux.statx(@intCast(fd), empty, linux.AT.EMPTY_PATH, mask, &sx);
        // `usize` syscall return: errors are -4096..-1 (i.e. very large usize).
        if (@as(isize, @bitCast(rc)) < 0) return Error.FstatFailed;
        return sx.size;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return Error.FstatFailed;
        return @intCast(st.size);
    }
}

// ── Producer ───────────────────────────────────────────────────────

pub const Producer = struct {
    base: [*]u8,
    total_size: usize,
    header: *Header,
    opts: Options,
    handle: Handle,
    name: [:0]const u8,
    /// Slot the producer is currently writing into. Rotates 0 → ring-1.
    next_slot: u32 = 0,

    /// Create + truncate + map the shm region. Sets `Header.magic`,
    /// dimensions, ring_size, slot_size. Caller can call `pixelsPtr`
    /// to write into the current slot, then `publish` to advance
    /// `latest` and bump `frame_count`.
    pub fn init(name: [:0]const u8, opts: Options) !Producer {
        // Reject malformed options up-front so we don't `mmap` a
        // zero-sized region or wrap arithmetic into an undersized
        // mapping. `pixelsPtr` assumes at least one slot; `publish`
        // mods by `ring_size`; `slotSize` would silently overflow on
        // huge dims (#546 review).
        if (!validateOptions(opts)) return Error.InvalidOptions;

        const total = totalSize(opts);
        const region = try createMapping(name, total);
        errdefer unmapRegion(&region);

        const header: *Header = @ptrCast(@alignCast(region.base));
        header.* = .{
            .magic = MAGIC,
            .version = PROTOCOL_VERSION,
            .pixel_format = PIXEL_FORMAT_RGBA8,
            .width = opts.width,
            .height = opts.height,
            .stride = opts.width * 4,
            .ring_size = opts.ring_size,
            .slot_size = slotSize(opts.width, opts.height),
            // Sentinel meaning "no slot published yet" — consumers gate on
            // `latest < ring_size`.
            .latest = opts.ring_size,
            .frame_count = 0,
            .shutdown = 0,
            ._pad = [_]u8{0} ** 4,
        };

        return .{
            .base = region.base,
            .total_size = region.total_size,
            .header = header,
            .opts = opts,
            .handle = region.handle,
            .name = name,
            .next_slot = 0,
        };
    }

    pub fn deinit(self: *Producer) void {
        const region: MappedRegion = .{
            .base = self.base,
            .total_size = self.total_size,
            .handle = self.handle,
        };
        unmapRegion(&region);
        // Best-effort: producer owns the lifecycle; remove the name.
        // No-op on Windows (section is reference-counted).
        unlinkName(self.name);
        self.base = undefined;
        self.header = undefined;
    }

    /// Returns the pixel bytes pointer for the *next* slot to fill.
    /// Producer writes RGBA8 pixels here (width*height*4 bytes), then
    /// calls `publish`.
    pub fn pixelsPtr(self: *Producer) [*]u8 {
        const slot_base = self.base + @sizeOf(Header) + @as(usize, @intCast(self.next_slot)) * @as(usize, @intCast(self.header.slot_size));
        return slot_base;
    }

    /// Returns the trailer pointer for the slot returned by the last
    /// `pixelsPtr` call. Producer may stamp `frame_idx` and
    /// `produce_ns` directly OR call `publish(stamp_now=true)`.
    pub fn trailerPtr(self: *Producer) *SlotTrailer {
        const slot_base = self.base + @sizeOf(Header) + @as(usize, @intCast(self.next_slot)) * @as(usize, @intCast(self.header.slot_size));
        const trailer_offset: usize = @as(usize, @intCast(self.header.slot_size)) - @sizeOf(SlotTrailer);
        return @ptrCast(@alignCast(slot_base + trailer_offset));
    }

    /// Publish the current slot. With `stamp_now=true` (the default)
    /// the trailer is written here with the current `nowNs()`; if the
    /// producer wants to stamp earlier (e.g. before GPU sync), pass
    /// `stamp_now=false` and write the trailer manually.
    pub fn publish(self: *Producer, stamp_now: bool) void {
        const new_frame_idx = self.header.frame_count + 1;
        if (stamp_now) {
            const trailer = self.trailerPtr();
            trailer.frame_idx = new_frame_idx;
            trailer.produce_ns = nowNs();
        }

        // Release-store `latest` first so any consumer that reads it has a
        // happens-before on the pixel writes + trailer. Then release-store
        // `frame_count` — consumer acquire-loads frame_count first, so the
        // ordering is: consumer sees new frame_count → acquire-load latest
        // → guaranteed to see the slot writes.
        @atomicStore(u32, &self.header.latest, self.next_slot, .release);
        @atomicStore(u64, &self.header.frame_count, new_frame_idx, .release);

        self.next_slot = (self.next_slot + 1) % self.header.ring_size;
    }
};

// ── Consumer ───────────────────────────────────────────────────────

pub const Consumer = struct {
    base: [*]u8,
    total_size: usize,
    header: *Header,
    name: [:0]const u8,
    handle: Handle,
    last_seen_frame: u64 = 0,

    /// Open + map an existing shm region created by the producer.
    /// Validates `Header.magic` and `version`.
    pub fn init(name: [:0]const u8) !Consumer {
        const region = try openMapping(name);
        errdefer unmapRegion(&region);

        const header: *Header = @ptrCast(@alignCast(region.base));
        // POSIX `openMapping` doesn't validate magic/version (the size
        // discovery happens via `fstat`, no header peek required); the
        // Windows path *does* validate so it can size the second map.
        // Keep the post-map check here so both platforms surface a
        // consistent error vocabulary.
        if (header.magic != MAGIC) return Error.BadMagic;
        if (header.version != PROTOCOL_VERSION) return Error.BadVersion;

        return .{
            .base = region.base,
            .total_size = region.total_size,
            .header = header,
            .name = name,
            .handle = region.handle,
            .last_seen_frame = 0,
        };
    }

    pub fn deinit(self: *Consumer) void {
        const region: MappedRegion = .{
            .base = self.base,
            .total_size = self.total_size,
            .handle = self.handle,
        };
        unmapRegion(&region);
        // Do NOT unlink — producer owns the lifecycle.
        self.base = undefined;
        self.header = undefined;
    }

    pub const Frame = struct {
        pixels: [*]const u8,
        width: u32,
        height: u32,
        stride: u32,
        frame_idx: u64,
        produce_ns: u64,
    };

    /// Returns the latest unread frame, or null if none new since last
    /// `latest` call. Mailbox semantics: only the most-recent frame is
    /// returned; older un-consumed frames are dropped.
    pub fn latest(self: *Consumer) ?Frame {
        // Acquire-load frame_count first — pairs with the release-store in
        // publish, ensuring we observe latest + slot bytes that were
        // committed before this counter bump.
        const fc = @atomicLoad(u64, &self.header.frame_count, .acquire);
        if (fc <= self.last_seen_frame) return null;

        const slot = @atomicLoad(u32, &self.header.latest, .acquire);
        if (slot >= self.header.ring_size) return null; // sentinel: never published

        const ring_size = self.header.ring_size;
        const slot_size: usize = @intCast(self.header.slot_size);
        const slot_base = self.base + @sizeOf(Header) + @as(usize, slot) * slot_size;
        const trailer: *const SlotTrailer = @ptrCast(@alignCast(slot_base + slot_size - @sizeOf(SlotTrailer)));

        const frame_idx = trailer.frame_idx;
        const produce_ns = trailer.produce_ns;

        // Race guard: if the producer is mid-publish on the same slot we just
        // looked at (slot index wraps every `ring_size` frames), the trailer
        // could be torn. We compare against last_seen_frame as a coarse
        // monotonicity check.
        if (frame_idx <= self.last_seen_frame) return null;

        self.last_seen_frame = frame_idx;
        _ = ring_size;
        return .{
            .pixels = slot_base,
            .width = self.header.width,
            .height = self.header.height,
            .stride = self.header.stride,
            .frame_idx = frame_idx,
            .produce_ns = produce_ns,
        };
    }
};

// ── Shutdown signaling ─────────────────────────────────────────────

pub fn signalShutdown(header: *Header) void {
    @atomicStore(u32, &header.shutdown, 1, .seq_cst);
}

pub fn isShuttingDown(header: *const Header) bool {
    // `@atomicLoad` requires a mutable pointer in older Zig; cast away const.
    const mut: *u32 = @constCast(&header.shutdown);
    return @atomicLoad(u32, mut, .seq_cst) != 0;
}

// ── Tests ──────────────────────────────────────────────────────────

test "totalSize layout sanity" {
    const opts: Options = .{ .width = 64, .height = 32, .ring_size = 3 };
    const slot = slotSize(64, 32);
    try std.testing.expect(slot >= 64 * 32 * 4 + @sizeOf(SlotTrailer));
    try std.testing.expect(slot % 64 == 0);
    try std.testing.expectEqual(@as(u64, @sizeOf(Header) + 3 * slot), totalSize(opts));
}

test "header is cacheline-aligned and stable size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SlotTrailer));
}

test "producer/consumer round-trip" {
    // Use a test-only name so we don't collide with a running game.
    const name: [:0]const u8 = "/imgui-preview-poc-test";
    // Best-effort cleanup from any prior aborted run.
    unlinkName(name);

    var producer = try Producer.init(name, .{ .width = 4, .height = 4, .ring_size = 2 });
    defer producer.deinit();

    var consumer = try Consumer.init(name);
    defer consumer.deinit();

    // Before any publish, latest() returns null (sentinel).
    try std.testing.expect(consumer.latest() == null);

    // Write a recognisable pattern, then publish.
    const pixels = producer.pixelsPtr();
    var i: usize = 0;
    while (i < 4 * 4 * 4) : (i += 1) pixels[i] = @intCast(i & 0xFF);
    producer.publish(true);

    const frame = consumer.latest() orelse return error.NoFrame;
    try std.testing.expectEqual(@as(u32, 4), frame.width);
    try std.testing.expectEqual(@as(u32, 4), frame.height);
    try std.testing.expectEqual(@as(u32, 16), frame.stride);
    try std.testing.expectEqual(@as(u64, 1), frame.frame_idx);
    try std.testing.expect(frame.produce_ns > 0);
    try std.testing.expectEqual(@as(u8, 0), frame.pixels[0]);
    try std.testing.expectEqual(@as(u8, 7), frame.pixels[7]);

    // Second call returns null (no new frame).
    try std.testing.expect(consumer.latest() == null);

    // Publish another, ensure consumer sees it.
    producer.publish(true);
    const frame2 = consumer.latest() orelse return error.NoFrame2;
    try std.testing.expectEqual(@as(u64, 2), frame2.frame_idx);

    // Shutdown signaling.
    try std.testing.expect(!isShuttingDown(producer.header));
    signalShutdown(producer.header);
    try std.testing.expect(isShuttingDown(producer.header));
}

test "windows mapping name conversion strips leading slash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const w = try windows.mappingNameFromPosix(std.testing.allocator, "/lbl-prv-1234-5678");
    defer std.testing.allocator.free(w);
    // "Local\lbl-prv-1234-5678" = 22 UTF-16 code units (no NUL terminator
    // counted by the slice length; the trailing NUL is past `.len`).
    try std.testing.expectEqual(@as(usize, 22), w.len);
    // First two code units are 'L' (0x4C), 'o' (0x6F).
    try std.testing.expectEqual(@as(u16, 'L'), w[0]);
    try std.testing.expectEqual(@as(u16, 'o'), w[1]);
}
