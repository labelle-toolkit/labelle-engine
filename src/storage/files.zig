//! Native file storage. The supplied absolute directory is a
//! namespace (normally <dataRoot>/saves). It is created only for writes.
const std = @import("std");
const storage = @import("../storage.zig");
// Kind/size/mtime without Zig 0.16's statx on Linux (see its header): every
// stat here goes through it, and directories are opened before they are
// created, since `createDirPath` stats a directory that already exists.
const file_info = @import("file_info.zig");

pub const Files = struct {
    io: std.Io,
    directory: []const u8,
    /// Crash-left staging files are purged on writes (the only path that
    /// touches `.pending`): on the first one, then again on the first write
    /// at or after this time whenever a previous purge kept a staging file
    /// that was still too young to be called abandoned. Null once a purge
    /// kept nothing.
    staging_purge_due: ?std.Io.Timestamp = .zero,

    pub const isStagingName = matchesStagingName;
    pub const isEntryCandidate = entryKindIsCandidate;
    pub const isStaleStaging = stagingIsStale;

    pub fn init(io: std.Io, absolute_directory: []const u8) storage.Error!Files {
        const platform: storage.dataRoot.Platform = if (@import("builtin").os.tag == .windows) .windows else .linux;
        if (!storage.dataRoot.isAbsolute(platform, absolute_directory)) return error.Unavailable;
        return .{ .io = io, .directory = absolute_directory };
    }

    pub fn store(self: *Files) storage.Store {
        return .{ .context = self, .begin_fn = begin };
    }

    fn begin(ctx: *anyopaque, allocator: std.mem.Allocator, request: storage.Request) storage.Error!storage.Operation {
        const self: *Files = @ptrCast(@alignCast(ctx));
        const result = self.execute(allocator, request) catch |err| return storage.mapError(err);
        return .{ .allocator = allocator, .state = .{ .ready = result } };
    }

    fn execute(self: *Files, allocator: std.mem.Allocator, request: storage.Request) !storage.Result {
        const io = self.io;
        if (request == .write) try ensureDir(io, std.Io.Dir.cwd(), self.directory);
        var dir = std.Io.Dir.cwd().openDir(io, self.directory, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) switch (request) {
                .list => return .{ .list = try allocator.alloc(storage.Entry, 0) },
                .delete => return .deleted,
                else => {},
            };
            return err;
        };
        defer dir.close(io);
        switch (request) {
            .read => |r| {
                // Never follow a symlink out of the namespace: a key that is
                // a link (ELOOP under O_NOFOLLOW; the reparse point itself on
                // Windows) or any other non-regular file is refused.
                const file = openKey(io, dir, r.name) catch |err| switch (err) {
                    error.SymLinkLoop, error.IsDir => return error.AccessDenied,
                    else => return err,
                };
                defer file.close(io);
                // Reader needs room for an EOF probe even for a zero-byte
                // limit. Check the public inclusive bound after that probe.
                // Streaming: read to EOF without asking the file's size,
                // which std would do with statx.
                var reader = file.readerStreaming(io, &.{});
                const bytes = reader.interface.allocRemaining(allocator, .limited(r.max_bytes +| 1)) catch |err| switch (err) {
                    error.ReadFailed => return reader.err.?,
                    error.OutOfMemory, error.StreamTooLong => |e| return e,
                };
                if (bytes.len > r.max_bytes) {
                    allocator.free(bytes);
                    return error.StreamTooLong;
                }
                return .{ .read = bytes };
            },
            .write => |w| {
                // Never truncate the last good save. Stage the full blob in
                // `.pending` (outside the public list), sync it, then rename
                // it over the key. A crash before the rename leaves only a
                // staging file, which a later write purges once it is
                // older than `staging_stale_ns` (see purgeStaging).
                try ensureDir(io, dir, ".pending");
                // No symlink following: a `.pending` that is not a real
                // directory inside the namespace is refused, never traversed.
                var staging = try dir.openDir(io, ".pending", .{ .iterate = true, .follow_symlinks = false });
                defer staging.close(io);
                if (self.staging_purge_due) |due| {
                    const now = std.Io.Timestamp.now(io, .real);
                    if (now.nanoseconds >= due.nanoseconds) self.staging_purge_due = purgeStaging(io, staging, now);
                }
                var staging_name: [staging_name_len]u8 = undefined;
                const file = while (true) {
                    var random_integer: u64 = undefined;
                    io.random(std.mem.asBytes(&random_integer));
                    staging_name = std.fmt.hex(random_integer);
                    break staging.createFile(io, &staging_name, .{ .exclusive = true }) catch |err| switch (err) {
                        error.PathAlreadyExists => continue,
                        else => return err,
                    };
                };
                var renamed = false;
                defer if (!renamed) staging.deleteFile(io, &staging_name) catch {};
                {
                    // Closed before the rename: Windows cannot rename an
                    // open file.
                    defer file.close(io);
                    try file.writeStreamingAll(io, w.bytes);
                    try file.sync(io);
                }
                try staging.rename(&staging_name, dir, w.name, io);
                renamed = true;
                return .written;
            },
            .delete => |name| {
                dir.deleteFile(io, name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                return .deleted;
            },
            .list => {
                var entries: std.ArrayList(storage.Entry) = .empty;
                errdefer {
                    for (entries.items) |entry| allocator.free(entry.name);
                    entries.deinit(allocator);
                }
                var iterator = dir.iterate();
                while (try iterator.next(io)) |entry| {
                    // Some filesystems (NFS, ...) report `.unknown` kinds;
                    // those are decided by lstat. Links are never blobs.
                    if (!entryKindIsCandidate(entry.kind)) continue;
                    storage.validateName(entry.name) catch continue;
                    const info = file_info.at(io, dir, entry.name) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    if (info.kind != .file) continue;
                    const name = try allocator.dupe(u8, entry.name);
                    errdefer allocator.free(name);
                    try entries.append(allocator, .{ .name = name, .size = info.size, .modified_ns = info.mtime_ns });
                }
                return .{ .list = try entries.toOwnedSlice(allocator) };
            },
        }
    }
};

/// Opens a key read-only without following a final symlink and rejects
/// anything that is not a regular file (AccessDenied). On POSIX the open is
/// non-blocking so a FIFO (or device) planted under a valid key cannot stall
/// the game thread waiting for a writer; O_NONBLOCK is cleared again once
/// fstat has proven the key is a regular file. Windows has no FIFOs in the
/// file namespace and keeps the portable open.
fn openKey(io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File {
    const os = @import("builtin").os.tag;
    if (os == .windows or os == .wasi) {
        var file = try dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false });
        errdefer file.close(io);
        if ((try file_info.ofFile(io, file)).kind != .file) return error.AccessDenied;
        // Zig 0.16's Windows no-follow open uses an asynchronous NT handle,
        // but returns nonblocking=false. A pending read then hits unreachable
        // instead of waiting for completion (Flying Platform #972). Match the
        // handle mode so File.Reader takes Threaded's APC/wait read path.
        if (os == .windows) file.flags.nonblocking = true;
        return file;
    }
    const posix = std.posix;
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const fd = try posix.openat(dir.handle, name, flags, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    if ((try file_info.ofFile(io, file)).kind != .file) return error.AccessDenied;
    const status = while (true) {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.Unexpected,
        }
    };
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, status & ~nonblock))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.Unexpected,
    };
    file.flags.nonblocking = false;
    return file;
}

/// Ensure each missing component exists without stat-based directory helpers.
/// Another writer may create a component between open and mkdir; validate
/// EEXIST by opening it, never by statting it (old Linux has no statx).
/// Namespace symlinks are followed; `.pending` is reopened no-follow by the
/// caller before any staging files are accessed.
fn ensureDir(io: std.Io, base: std.Io.Dir, path: []const u8) !void {
    if (base.openDir(io, path, .{})) |opened| {
        opened.close(io);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var components = std.Io.Dir.path.componentIterator(path);
    var component = components.last() orelse return error.BadPathName;
    while (true) {
        base.createDir(io, component.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const opened = try base.openDir(io, component.path, .{});
                opened.close(io);
            },
            error.FileNotFound => |e| {
                component = components.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = components.next() orelse return;
    }
}

/// Staging files are exactly 16 lowercase hex digits (a random u64).
pub const staging_name_len = 16;

fn matchesStagingName(name: []const u8) bool {
    if (name.len != staging_name_len) return false;
    for (name) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Directory-entry kinds worth a stat: regular files, plus `.unknown` from
/// filesystems whose iteration does not report a type (the stat decides).
fn entryKindIsCandidate(kind: std.Io.File.Kind) bool {
    return kind == .file or kind == .unknown;
}

/// Another process (or another `Files` on the same namespace) may be mid-
/// write; a staging file is only considered abandoned once it is this old.
pub const staging_stale_ns: i96 = 10 * std.time.ns_per_min;

fn stagingIsStale(modified: std.Io.Timestamp, now: std.Io.Timestamp) bool {
    return now.nanoseconds - modified.nanoseconds > staging_stale_ns;
}

/// Best-effort removal of staging files left by an interrupted write. Only
/// regular files directly inside `.pending` whose names match the staging
/// pattern AND whose mtime is older than `staging_stale_ns` are removed, so
/// a concurrent writer's live staging file is never touched. Symlinks,
/// directories and foreign names are left alone; unlink never follows a link.
/// Returns the earliest time a kept (still young) staging file turns stale,
/// so a later write can reconsider it, or null when nothing young was kept.
/// A failed scan is retried on the next write.
fn purgeStaging(io: std.Io, staging: std.Io.Dir, now: std.Io.Timestamp) ?std.Io.Timestamp {
    var due: ?std.Io.Timestamp = null;
    var iterator = staging.iterate();
    while (iterator.next(io) catch return now) |entry| {
        if (!entryKindIsCandidate(entry.kind) or !matchesStagingName(entry.name)) continue;
        const info = file_info.at(io, staging, entry.name) catch continue;
        if (info.kind != .file) continue;
        const modified: std.Io.Timestamp = .fromNanoseconds(info.mtime_ns);
        if (!stagingIsStale(modified, now)) {
            // Stale once strictly older than the safety age.
            const stale_at: std.Io.Timestamp = .fromNanoseconds(info.mtime_ns +| (staging_stale_ns + 1));
            if (due == null or stale_at.nanoseconds < due.?.nanoseconds) due = stale_at;
            continue;
        }
        staging.deleteFile(io, entry.name) catch {};
    }
    return due;
}
