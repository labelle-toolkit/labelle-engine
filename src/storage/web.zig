//! Adapter for a platform's IndexedDB bridge. Bindings implement the ABI in
//! docs/persistent-blobs.md; importing this never links a particular backend.
const std = @import("std");
const storage = @import("../storage.zig");

pub fn Web(comptime Bindings: type) type {
    return struct {
        namespace: []const u8,
        const Self = @This();
        const Pending = struct { id: u32, kind: std.meta.Tag(storage.Request), max_bytes: usize };

        pub fn store(self: *Self) storage.Store {
            return .{ .context = self, .begin_fn = begin };
        }

        fn begin(ctx: *anyopaque, allocator: std.mem.Allocator, request: storage.Request) storage.Error!storage.Operation {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try storage.validateName(self.namespace);
            var name: []const u8 = "";
            var bytes: []const u8 = "";
            var limit: usize = 0;
            const kind: u32 = switch (request) {
                .read => |r| blk: {
                    name = r.name;
                    limit = r.max_bytes;
                    break :blk 0;
                },
                .write => |w| blk: {
                    name = w.name;
                    bytes = w.bytes;
                    break :blk 1;
                },
                .list => 2,
                .delete => |n| blk: {
                    name = n;
                    break :blk 3;
                },
            };
            const pending = try allocator.create(Pending);
            errdefer allocator.destroy(pending);
            const id = Bindings.begin(self.namespace, kind, name, bytes, limit);
            if (id == 0) return error.Unavailable;
            pending.* = .{ .id = id, .kind = std.meta.activeTag(request), .max_bytes = limit };
            return .{ .allocator = allocator, .state = .{ .pending = .{
                .context = pending,
                .poll = poll,
                .deinit = deinit,
            } } };
        }

        fn poll(ctx: *anyopaque, allocator: std.mem.Allocator) storage.Error!?storage.Result {
            const pending: *Pending = @ptrCast(@alignCast(ctx));
            switch (Bindings.status(pending.id)) {
                0 => return null,
                1 => {},
                -1 => return error.NotFound,
                -2 => return error.QuotaExceeded,
                -3 => return error.Unavailable,
                -4 => return error.AccessDenied,
                -5 => return error.TooLarge,
                else => return error.IoFailure,
            }
            switch (pending.kind) {
                .write => return .written,
                .delete => return .deleted,
                .read, .list => {},
            }
            const size = Bindings.length(pending.id);
            if (pending.kind == .read and size > pending.max_bytes) return error.TooLarge;
            const bytes = try allocator.alloc(u8, size);
            if (!Bindings.copy(pending.id, bytes)) {
                allocator.free(bytes);
                return error.IoFailure;
            }
            if (pending.kind == .read) return .{ .read = bytes };
            defer allocator.free(bytes);
            // The bridge emits only list metadata, never save contents.
            const WireEntry = struct { name: []const u8, size: u64, modified_ms: i64 };
            const parsed = std.json.parseFromSlice([]WireEntry, allocator, bytes, .{}) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.IoFailure,
            };
            defer parsed.deinit();
            var entries: std.ArrayList(storage.Entry) = .empty;
            errdefer {
                for (entries.items) |entry| allocator.free(entry.name);
                entries.deinit(allocator);
            }
            for (parsed.value) |entry| {
                storage.validateName(entry.name) catch return error.IoFailure;
                const owned = try allocator.dupe(u8, entry.name);
                errdefer allocator.free(owned);
                try entries.append(allocator, .{ .name = owned, .size = entry.size, .modified_ns = @as(i128, entry.modified_ms) * 1_000_000 });
            }
            return .{ .list = try entries.toOwnedSlice(allocator) };
        }

        fn deinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            const pending: *Pending = @ptrCast(@alignCast(ctx));
            Bindings.release(pending.id);
            allocator.destroy(pending);
        }
    };
}
