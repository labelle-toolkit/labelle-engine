//! Platform-specific socket I/O shims for preview mode (#551 Windows port).
//!
//! Extracted from `preview_mode.zig` verbatim — behavior-preserving.
//! The control channel bypasses `std.Io.net.Stream`'s typed reader/
//! writer and goes straight to the raw fd, so these tiny wrappers give
//! us a cross-platform `read` / `write` / `close` / non-blocking toggle
//! without threading `io: std.Io` through every call site.

const std = @import("std");
const builtin = @import("builtin");

// ── Platform-specific socket I/O shims (#551 Windows port) ─────────
//
// std.posix in 0.16 dropped top-level `close` and `write` wrappers
// and routed file IO through `std.Io.File` (which needs an `io:
// std.Io` reference we'd otherwise have to thread through every call
// site). On POSIX we bind libc's read / write / close / fcntl
// directly. On Windows we bind the ws2_32 socket-only variants
// (recv / send / closesocket / ioctlsocket) — Win32's plain `read` /
// `write` don't accept SOCKET handles, and the fcntl-based
// non-blocking path is replaced by ioctlsocket(FIONBIO, …).
const socket_io = if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    pub const SOCKET = win.HANDLE;

    pub extern "ws2_32" fn recv(
        s: SOCKET,
        buf: [*]u8,
        len: c_int,
        flags: c_int,
    ) callconv(.winapi) c_int;

    pub extern "ws2_32" fn send(
        s: SOCKET,
        buf: [*]const u8,
        len: c_int,
        flags: c_int,
    ) callconv(.winapi) c_int;

    pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;

    pub extern "ws2_32" fn ioctlsocket(
        s: SOCKET,
        cmd: i32,
        argp: *u_long,
    ) callconv(.winapi) c_int;

    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

    pub const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667e));
    pub const WSAEWOULDBLOCK: c_int = 10035;
    pub const SOCKET_ERROR: c_int = -1;
    // `unsigned long` in Win32 is always 32-bit (LLP64); spell it out
    // explicitly so we don't depend on whether `c_ulong` resolves to
    // 32 or 64 bits under cross-compilation toolchains.
    pub const u_long = u32;
} else struct {
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
    // `fcntl` is variadic in libc (`int fcntl(int, int, ...)`). On
    // aarch64-darwin (and other ABIs that put variadic args on the
    // stack rather than in registers), declaring it as non-variadic
    // with `arg: c_int` is a calling-convention mismatch — F_SETFL
    // receives stack garbage instead of the flag value, O_NONBLOCK
    // never gets set, and the next `read` blocks. Use the stdlib's
    // correctly-declared `std.c.fcntl` instead (see `lib/std/c.zig`).
    pub const c_fcntl = std.c.fcntl;
    extern "c" fn __error() *c_int; // macOS errno location
    extern "c" fn __errno_location() *c_int; // glibc errno location
    extern "c" fn __errno() *c_int; // Bionic errno location (Android)

    pub fn errno() c_int {
        // Bionic (Android) ships `__errno`, not `__errno_location`.
        // Compile-time pick by ABI so the dead branch's extern ref is
        // dropped by Zig's linker on each target.
        const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;
        if (comptime is_android) return __errno().*;
        return if (builtin.os.tag == .macos) __error().* else __errno_location().*;
    }

    pub const F_GETFL: c_int = 3;
    pub const F_SETFL: c_int = 4;
    pub const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 4 else 2048;
    pub const EAGAIN: c_int = if (builtin.os.tag == .macos) 35 else 11;

    pub fn raw_close(fd: c_int) c_int {
        return close(fd);
    }
    pub fn raw_write(fd: c_int, buf: [*]const u8, len: usize) isize {
        return write(fd, buf, len);
    }
    pub fn raw_read(fd: c_int, buf: [*]u8, len: usize) isize {
        return read(fd, buf, len);
    }
};

/// Write up to `len` bytes from `buf` to the socket. Returns the
/// number of bytes written, or a negative value on error. Mirrors
/// libc's `write` shape on POSIX and `send` on Windows (mapping
/// `SOCKET_ERROR` to -1).
pub fn socketWrite(fd: std.posix.fd_t, buf: [*]const u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        // ws2_32 send caps at INT_MAX; downstream callers always
        // loop until len bytes are consumed, so capping per-call is
        // safe.
        const chunk: c_int = @intCast(@min(len, @as(usize, @intCast(std.math.maxInt(c_int)))));
        const n = socket_io.send(fd, buf, chunk, 0);
        if (n == socket_io.SOCKET_ERROR) return -1;
        return @intCast(n);
    } else {
        return socket_io.raw_write(fd, buf, len);
    }
}

pub fn socketRead(fd: std.posix.fd_t, buf: [*]u8, len: usize) isize {
    if (builtin.os.tag == .windows) {
        const chunk: c_int = @intCast(@min(len, @as(usize, @intCast(std.math.maxInt(c_int)))));
        const n = socket_io.recv(fd, buf, chunk, 0);
        if (n == socket_io.SOCKET_ERROR) return -1;
        return @intCast(n);
    } else {
        return socket_io.raw_read(fd, buf, len);
    }
}

pub fn socketClose(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        _ = socket_io.closesocket(fd);
    } else {
        _ = socket_io.raw_close(fd);
    }
}

/// Switch the socket into non-blocking mode. Returns null on failure.
/// POSIX: read-modify-write via `fcntl(F_GETFL/F_SETFL)`. The caller
/// stashes the original flags so the defer can restore them. Windows:
/// `ioctlsocket(FIONBIO, 1)` is a single idempotent toggle — the
/// original "state" is just "blocking" and `restoreBlocking` flips
/// back to 0.
pub fn setNonBlocking(fd: std.posix.fd_t) ?BlockingState {
    if (builtin.os.tag == .windows) {
        var nb: socket_io.u_long = 1;
        if (socket_io.ioctlsocket(fd, socket_io.FIONBIO, &nb) != 0) return null;
        return .{ .windows = {} };
    } else {
        const orig = socket_io.c_fcntl(fd, socket_io.F_GETFL, @as(c_int, 0));
        if (orig < 0) return null;
        const set_rc = socket_io.c_fcntl(fd, socket_io.F_SETFL, @as(c_int, orig | socket_io.O_NONBLOCK));
        if (set_rc < 0) return null;
        return .{ .posix = orig };
    }
}

pub fn restoreBlocking(fd: std.posix.fd_t, state: BlockingState) void {
    if (builtin.os.tag == .windows) {
        // state is `union(enum) { windows }` here — single variant,
        // no inner data. We don't need to inspect it; the side effect
        // is "ioctlsocket back to blocking".
        var nb: socket_io.u_long = 0;
        _ = socket_io.ioctlsocket(fd, socket_io.FIONBIO, &nb);
        switch (state) {
            .windows => {},
        }
    } else {
        _ = socket_io.c_fcntl(fd, socket_io.F_SETFL, @as(c_int, state.posix));
    }
}

pub const BlockingState = if (builtin.os.tag == .windows)
    union(enum) { windows }
else
    union(enum) { posix: c_int };

/// True when the last `socketRead` / `socketWrite` failed because the
/// socket would have blocked. POSIX: `errno == EAGAIN`. Windows:
/// `WSAGetLastError() == WSAEWOULDBLOCK`.
pub fn wouldBlock() bool {
    if (builtin.os.tag == .windows) {
        return socket_io.WSAGetLastError() == socket_io.WSAEWOULDBLOCK;
    } else {
        return socket_io.errno() == socket_io.EAGAIN;
    }
}

/// Windows `GetCurrentProcessId` — used by `allocShmName` so the shm
/// fingerprint is a real PID (not a HANDLE, which is what
/// `std.c.getpid()` becomes on Windows).
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub fn getCurrentProcessId() u32 {
    return GetCurrentProcessId();
}
