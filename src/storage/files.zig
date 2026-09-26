//! Desktop/Android file storage. The supplied absolute directory is a
//! namespace (normally <dataRoot>/saves). It is created only for writes.
const std = @import("std");
const storage = @import("../storage.zig");

pub const Files = struct {
    io: std.Io,
    directory: []const u8,
    /// Crash-left staging files are purged once per store, on its first
    /// write (the only path that touches `.pending`).
    staging_purged: bool = false,

    pub const isStagingName = matchesStagingName;

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
        if (request == .write) try std.Io.Dir.cwd().createDirPath(io, self.directory);
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
                // Reader needs room for an EOF probe even for a zero-byte
                // limit. Check the public inclusive bound after that probe.
                const bytes = try dir.readFileAlloc(io, r.name, allocator, .limited(r.max_bytes +| 1));
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
                // staging file, which the next write through this store
                // purges (see purgeStaging).
                try dir.createDirPath(io, ".pending");
                // No symlink following: a `.pending` that is not a real
                // directory inside the namespace is refused, never traversed.
                var staging = try dir.openDir(io, ".pending", .{ .iterate = true, .follow_symlinks = false });
                defer staging.close(io);
                if (!self.staging_purged) {
                    purgeStaging(io, staging);
                    self.staging_purged = true;
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
                    if (entry.kind != .file) continue;
                    storage.validateName(entry.name) catch continue;
                    const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    const name = try allocator.dupe(u8, entry.name);
                    errdefer allocator.free(name);
                    try entries.append(allocator, .{ .name = name, .size = stat.size, .modified_ns = stat.mtime.nanoseconds });
                }
                return .{ .list = try entries.toOwnedSlice(allocator) };
            },
        }
    }
};

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

/// Best-effort removal of staging files left by an interrupted write. Only
/// regular files directly inside `.pending` whose names match the staging
/// pattern are removed; symlinks, directories and foreign names are left
/// alone, and unlink never follows a link. Writes are synchronous on the
/// calling thread, so no live staging file of this store exists here.
fn purgeStaging(io: std.Io, staging: std.Io.Dir) void {
    var iterator = staging.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (entry.kind != .file or !matchesStagingName(entry.name)) continue;
        staging.deleteFile(io, entry.name) catch {};
    }
}
