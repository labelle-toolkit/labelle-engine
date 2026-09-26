//! Persistent named blobs, independent of serialization, slots and providers.
//! Operations own their inputs after begin returns. Poll on the game thread;
//! null means pending, not success. A result is transferred exactly once.
const std = @import("std");
pub const Files = @import("storage/files.zig").Files;
pub const dataRoot = @import("storage/data_root.zig");
pub const Web = @import("storage/web.zig").Web;

pub const Error = error{
    InvalidName,
    InvalidOperation,
    NotFound,
    TooLarge,
    QuotaExceeded,
    Unavailable,
    AccessDenied,
    ReadOnly,
    IoFailure,
    OutOfMemory,
};
pub const Entry = struct { name: []u8, size: u64, modified_ns: i128 };
pub const Request = union(enum) {
    read: struct { name: []const u8, max_bytes: usize },
    write: struct { name: []const u8, bytes: []const u8 },
    list,
    delete: []const u8,
};
pub const Result = union(enum) {
    read: []u8,
    list: []Entry,
    written,
    deleted,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .read => |bytes| allocator.free(bytes),
            .list => |entries| {
                for (entries) |entry| allocator.free(entry.name);
                allocator.free(entries);
            },
            else => {},
        }
    }
};

/// Move-only by convention, like std ArrayList. Always deinit, even on error.
/// Dropping a pending operation releases its observer; it does NOT promise
/// cancellation of a write already submitted to persistent storage.
pub const Operation = struct {
    allocator: std.mem.Allocator,
    state: union(enum) { ready: Result, pending: Pending, consumed },
    pub const Pending = struct {
        context: *anyopaque,
        poll: *const fn (*anyopaque, std.mem.Allocator) Error!?Result,
        deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn poll(self: *Operation) Error!?Result {
        switch (self.state) {
            .consumed => return error.InvalidOperation,
            .ready => |result| {
                self.state = .consumed;
                return result;
            },
            .pending => |p| {
                const result = p.poll(p.context, self.allocator) catch |err| {
                    p.deinit(p.context, self.allocator);
                    self.state = .consumed;
                    return err;
                };
                if (result != null) {
                    p.deinit(p.context, self.allocator);
                    self.state = .consumed;
                }
                return result;
            },
        }
    }

    pub fn deinit(self: *Operation) void {
        switch (self.state) {
            .ready => |result| result.deinit(self.allocator),
            .pending => |p| p.deinit(p.context, self.allocator),
            .consumed => {},
        }
        self.state = .consumed;
    }
};

/// A resolved target supplies exactly one Store. Package conflict detection
/// belongs to the resolver; this interface has no global registration or
/// last-writer-wins fallback. Store context must outlive begin calls.
pub const Store = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, std.mem.Allocator, Request) Error!Operation,

    pub fn begin(self: Store, allocator: std.mem.Allocator, request: Request) Error!Operation {
        switch (request) {
            .read => |r| try validateName(r.name),
            .write => |w| try validateName(w.name),
            .delete => |name| try validateName(name),
            .list => {},
        }
        return self.begin_fn(self.context, allocator, request);
    }
};

/// Portable single-component UTF-8 key; no paths, Windows device names or
/// alternate data streams. Sidecars such as colony.meta are ordinary keys.
pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
    if (name[0] == '.' or name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.InvalidName;
    for (name) |c| if (c < 32 or c == 127 or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", c) != null) return error.InvalidName;
    const stem = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return error.InvalidName;
    }
    if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9' and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) return error.InvalidName;
}

pub fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.NotFound,
        error.StreamTooLong => error.TooLarge,
        error.NoSpaceLeft, error.DiskQuota => error.QuotaExceeded,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.ReadOnlyFileSystem => error.ReadOnly,
        else => error.IoFailure,
    };
}
