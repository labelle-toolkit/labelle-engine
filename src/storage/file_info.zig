//! A file's kind, size and modified time, for native storage, without
//! `statx` on Linux.
//!
//! Zig 0.16's `std.Io.Threaded` stats with `statx`, which Linux only has
//! since 4.11, and has no fallback: on an older kernel every stat fails with
//! ENOSYS (`error.Unexpected`). In Debug builds `posix.unexpectedErrno` then
//! dumps a stack trace, whose symbol lookup stats the executable again and
//! deadlocks on its own lock. Mobile devices still ship 3.x/4.4/4.9 Linux
//! kernels (a 3.18 test tablet could not list, read or write any save). So
//! on Linux arm64/x86_64 this asks with `newfstatat`, which every kernel
//! since 2.6.16 has and which the system C libraries' own `stat` uses. Every
//! other target keeps `std.Io`'s stat.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Info = struct {
    kind: std.Io.File.Kind,
    size: u64,
    mtime_ns: i96,
};

pub const Error = error{ FileNotFound, AccessDenied, SymLinkLoop, NameTooLong, Unexpected };

const use_fstatat = builtin.os.tag == .linux and switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

/// The kernel's `struct stat` (`newfstatat`): asm-generic on arm64,
/// `arch/x86/include/uapi/asm/stat.h` on x86_64.
const KernelStat = switch (builtin.cpu.arch) {
    .aarch64 => extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        _pad1: u64,
        size: i64,
        blksize: i32,
        _pad2: i32,
        blocks: i64,
        atime: i64,
        atime_nsec: u64,
        mtime: i64,
        mtime_nsec: u64,
        ctime: i64,
        ctime_nsec: u64,
        _unused: [2]u32,
    },
    .x86_64 => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        _pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atime: i64,
        atime_nsec: u64,
        mtime: i64,
        mtime_nsec: u64,
        ctime: i64,
        ctime_nsec: u64,
        _unused: [3]i64,
    },
    else => void,
};

/// `name` inside `dir`, never following a final symlink (a link reports
/// `.sym_link`).
pub fn at(io: std.Io, dir: std.Io.Dir, name: []const u8) Error!Info {
    if (comptime use_fstatat) {
        var path: [std.fs.max_name_bytes + 1]u8 = undefined;
        if (name.len >= path.len) return error.NameTooLong;
        @memcpy(path[0..name.len], name);
        path[name.len] = 0;
        return fstatat(dir.handle, @ptrCast(&path), linux.AT.SYMLINK_NOFOLLOW);
    }
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return mapStdError(err);
    return .{ .kind = st.kind, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

/// An open file.
pub fn ofFile(io: std.Io, file: std.Io.File) Error!Info {
    if (comptime use_fstatat) return fstatat(file.handle, "", linux.AT.EMPTY_PATH);
    const st = file.stat(io) catch |err| return mapStdError(err);
    return .{ .kind = st.kind, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

fn fstatat(dirfd: linux.fd_t, path: [*:0]const u8, flags: u32) Error!Info {
    var st: KernelStat = undefined;
    while (true) {
        const rc = linux.syscall4(.fstatat64, @as(usize, @bitCast(@as(isize, dirfd))), @intFromPtr(path), @intFromPtr(&st), flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{
                .kind = kindOf(st.mode),
                .size = @intCast(@max(st.size, 0)),
                .mtime_ns = @as(i96, st.mtime) * std.time.ns_per_s + @as(i96, @intCast(st.mtime_nsec)),
            },
            .INTR => continue,
            .NOENT, .NOTDIR => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            else => return error.Unexpected,
        }
    }
}

/// `st_mode`'s file type bits (`S_IFMT`).
pub fn kindOf(mode: u32) std.Io.File.Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .directory,
        0o120000 => .sym_link,
        0o010000 => .named_pipe,
        0o140000 => .unix_domain_socket,
        0o020000 => .character_device,
        0o060000 => .block_device,
        else => .unknown,
    };
}

fn mapStdError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.NameTooLong => error.NameTooLong,
        else => error.Unexpected,
    };
}
