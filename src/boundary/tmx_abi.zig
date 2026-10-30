//! C-ABI contract of the independently compiled TMX loader
//! (labelle-engine#923 PROTOTYPE — not a supported API).
//!
//! The loader lives in `tmx_rt.zig`, which a consumer compiles as its own
//! static library (its own Zcu / LLVM module), so a game-only edit reuses
//! the cached object instead of re-running LLVM over the TMX parser inside
//! the game compilation unit. Only C-ABI functions, C-ABI callbacks, plain
//! integers and raw pointers cross the boundary; the decoded value is
//! written into caller memory guarded by `layout.fingerprint`.
const std = @import("std");
const builtin = @import("builtin");

pub const abi_version: u32 = 1;

/// Build flags that must agree between the two units. The linker does NOT
/// reject a single-threaded object inside a threaded (shared-memory) link
/// (measured, labelle-engine#923), so the unit checks it itself: a
/// single-threaded Zig unit compiles `std.Thread.Mutex` & co. to no-ops and
/// `threadlocal` to plain globals, which would be a silent data race.
pub fn buildFlags() u32 {
    var f: u32 = 0;
    if (builtin.single_threaded) f |= 1 << 0;
    f |= @as(u32, @intFromEnum(builtin.mode)) << 4;
    // CPU feature set (atomics / bulk memory / ...), folded to 16 bits.
    const fh = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&builtin.cpu.features.ints));
    f |= @as(u32, @as(u16, @truncate(fh))) << 16;
    return f;
}

pub const Status = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    parse_failed = 2,
    abi_mismatch = 3,
    _,
};

/// Borrowed-bytes resolver for external `.tsx` sources (mirrors
/// `TilesetSourceResolver`, but C-ABI so it can be called across units).
pub const ResolveFn = *const fn (
    context: ?*anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    out_ptr: *[*]const u8,
    out_len: *usize,
) callconv(.c) bool;

pub const Externs = struct {
    pub extern fn labelle_rt_abi_version() callconv(.c) u32;
    /// `buildFlags()` as the library unit computed it.
    pub extern fn labelle_rt_build_flags() callconv(.c) u32;
    /// Decode `content` into `out` (a `*TileMap` of `out_size` bytes whose
    /// layout hashes to `layout`). Allocates with the C allocator; the caller
    /// owns the result and must free it through a malloc-backed allocator.
    pub extern fn labelle_rt_tmx_load(
        content_ptr: [*]const u8,
        content_len: usize,
        resolver_ctx: ?*anyopaque,
        resolver: ?ResolveFn,
        out: *anyopaque,
        out_size: usize,
        layout: u64,
    ) callconv(.c) Status;
    /// Name of the last error returned by `labelle_rt_tmx_load` on this
    /// thread (static storage).
    pub extern fn labelle_rt_last_error(len: *usize) callconv(.c) [*]const u8;
};
