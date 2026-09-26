//! Desktop/Android file storage. The supplied absolute directory is a
//! namespace (normally <dataRoot>/saves). It is created only for writes.
const std = @import("std");
const storage = @import("../storage.zig");

pub const Files = struct {
    io: std.Io,
    directory: []const u8,

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
                // Never truncate the last good save. Atomic's temporary file
                // is removed on failure; sync data before replacing the name.
                // Keep crash-left temporary files outside the public list.
                try dir.createDirPath(io, ".pending");
                var staging = try dir.openDir(io, ".pending", .{});
                defer staging.close(io);
                var destination_buffer: [132]u8 = undefined;
                const destination = try std.fmt.bufPrint(&destination_buffer, "../{s}", .{w.name});
                var file = try staging.createFileAtomic(io, destination, .{ .replace = true });
                defer file.deinit(io);
                try file.file.writeStreamingAll(io, w.bytes);
                try file.file.sync(io);
                try file.replace(io);
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
