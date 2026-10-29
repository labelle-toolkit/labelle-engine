//! Typed preferences over storage.Store, including asynchronous stores.
//! T must own its values (no borrowed slices). Codec.decode(bytes) returns T;
//! Codec.encode(T, buffer) returns ![]const u8. The codec owns validation,
//! schema migration and malformed-data defaults. Keep settings separate from
//! save slots by selecting a dedicated Store namespace/directory.
const std = @import("std");
const storage = @import("storage.zig");
pub const Store = storage.Store;

pub fn Settings(comptime T: type, comptime Codec: type, comptime max_bytes: usize) type {
    return struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        value: T,
        queued: T,
        loaded: bool = false,
        disabled: bool = false,
        edited: bool = false,
        unsaved: bool = false,
        dirty: bool = false,
        started: bool = false,
        reading: bool = false,
        operation: ?storage.Operation = null,
        const Self = @This();

        /// name must outlive this object; the Store must outlive operations.
        pub fn init(allocator: std.mem.Allocator, name: []const u8, defaults: T) Self {
            return .{ .allocator = allocator, .name = name, .value = defaults, .queued = defaults };
        }
        pub fn deinit(self: *Self) void {
            if (self.operation) |*op| op.deinit();
            self.operation = null;
        }
        /// True after a read, missing/corrupt data fallback, or disable().
        /// Callers can gate their first localized UI on this without blocking.
        pub fn ready(self: *const Self) bool {
            return self.loaded;
        }
        pub fn get(self: *const Self) T {
            return self.value;
        }
        pub fn set(self: *Self, value: T) void {
            self.value = value;
            self.edited = true;
            self.unsaved = true;
        }
        /// Snapshot now; later uncommitted edits must not leak into this save.
        /// Multiple saves while a write is pending coalesce to the newest one.
        pub fn save(self: *Self) void {
            self.queued = self.value;
            self.dirty = true;
            self.unsaved = false;
        }
        pub fn saveIfChanged(self: *Self) void {
            if (self.unsaved) self.save();
        }
        /// Continue in memory if the provider cannot open or startup times out.
        /// Submitted writes may still complete; dropping an observer is not undo.
        pub fn disable(self: *Self) void {
            self.deinit();
            self.disabled = true;
            self.loaded = true;
        }
        /// Call on the game thread, also while paused. Never busy-wait for ready.
        /// Read failures keep defaults and permit future saves. Write failures
        /// stop persistence for this instance, retaining live settings in memory.
        pub fn pump(self: *Self, store: storage.Store) !void {
            if (self.disabled) return;
            if (self.operation == null) {
                if (!self.started) {
                    self.started = true;
                    self.reading = true;
                    self.operation = store.begin(self.allocator, .{ .read = .{ .name = self.name, .max_bytes = max_bytes } }) catch |err| return self.failed(err);
                } else if (self.loaded and self.dirty) {
                    self.reading = false;
                    var buf: [max_bytes]u8 = undefined;
                    const bytes = Codec.encode(self.queued, &buf) catch |err| return self.failed(err);
                    self.dirty = false;
                    self.operation = store.begin(self.allocator, .{ .write = .{ .name = self.name, .bytes = bytes } }) catch |err| return self.failed(err);
                } else return;
            }
            const result = (self.operation.?.poll() catch |err| return self.failed(err)) orelse return;
            defer result.deinit(self.allocator);
            self.deinit();
            if (self.reading) {
                self.loaded = true;
                // A user's change always wins over an older async read.
                if (!self.edited) self.value = Codec.decode(result.read);
            }
        }
        fn failed(self: *Self, err: anyerror) !void {
            self.deinit();
            if (self.reading) {
                self.loaded = true;
                if (err == error.NotFound) return;
            } else self.disabled = true;
            return err;
        }
    };
}

const TestCodec = struct {
    pub fn decode(bytes: []const u8) u8 {
        return std.fmt.parseInt(u8, bytes, 10) catch 7;
    }
    pub fn encode(value: u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{value});
    }
};
const TestStore = struct {
    data: [16]u8 = undefined,
    len: usize = 0,
    pending: bool = false,
    writes: usize = 0,
    fail_write: bool = false,
    delay_write: bool = false,
    writing: bool = false,
    fn store(self: *@This()) storage.Store {
        return .{ .context = self, .begin_fn = begin };
    }
    fn begin(ctx: *anyopaque, a: std.mem.Allocator, req: storage.Request) storage.Error!storage.Operation {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (req == .read) return .{ .allocator = a, .state = .{ .pending = .{ .context = self, .poll = poll, .deinit = release } } };
        if (self.fail_write) return error.QuotaExceeded;
        const bytes = req.write.bytes;
        @memcpy(self.data[0..bytes.len], bytes);
        self.len = bytes.len;
        self.writes += 1;
        if (self.delay_write) {
            self.writing = true;
            return .{ .allocator = a, .state = .{ .pending = .{ .context = self, .poll = poll, .deinit = release } } };
        }
        return .{ .allocator = a, .state = .{ .ready = .written } };
    }
    fn poll(ctx: *anyopaque, a: std.mem.Allocator) storage.Error!?storage.Result {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.pending) return null;
        if (self.writing) {
            self.writing = false;
            return .written;
        }
        if (self.len == 0) return error.NotFound;
        return .{ .read = try a.dupe(u8, self.data[0..self.len]) };
    }
    fn release(_: *anyopaque, _: std.mem.Allocator) void {}
};
test "async read gates readiness and cannot overwrite a user edit" {
    var store: TestStore = .{ .pending = true, .len = 1 };
    store.data[0] = '9';
    var s = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    defer s.deinit();
    try s.pump(store.store());
    try std.testing.expect(!s.ready());
    s.set(3);
    store.pending = false;
    try s.pump(store.store());
    try std.testing.expect(s.ready());
    try std.testing.expectEqual(@as(u8, 3), s.get());
    try std.testing.expectEqual(@as(usize, 0), store.writes);
}
test "save snapshots, coalesces and restores on next launch" {
    var store: TestStore = .{};
    var s = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    defer s.deinit();
    try s.pump(store.store());
    s.set(2);
    s.save();
    s.set(4);
    s.save();
    s.set(8);
    try s.pump(store.store());
    try std.testing.expectEqualStrings("4", store.data[0..store.len]);
    try std.testing.expectEqual(@as(usize, 1), store.writes);
    s.saveIfChanged();
    try s.pump(store.store());
    var reopened = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    defer reopened.deinit();
    try reopened.pump(store.store());
    try std.testing.expectEqual(@as(u8, 8), reopened.get());
}
test "malformed data and unavailable writes keep usable memory settings" {
    var store: TestStore = .{ .len = 1, .fail_write = true };
    store.data[0] = '?';
    var s = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    defer s.deinit();
    try s.pump(store.store());
    try std.testing.expectEqual(@as(u8, 7), s.get());
    s.set(3);
    s.save();
    try std.testing.expectError(error.QuotaExceeded, s.pump(store.store()));
    try std.testing.expect(s.ready() and s.disabled);
    s.set(5);
    s.save();
    try s.pump(store.store());
    try std.testing.expectEqual(@as(u8, 5), s.get());
}
test "startup timeout can abandon a pending read without changing defaults" {
    var store: TestStore = .{ .pending = true };
    var s = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    try s.pump(store.store());
    s.disable();
    try std.testing.expect(s.ready() and s.operation == null);
    try std.testing.expectEqual(@as(u8, 7), s.get());
}

test "new saves during an asynchronous write survive completion" {
    var store: TestStore = .{};
    var s = Settings(u8, TestCodec, 16).init(std.testing.allocator, "setting.json", 7);
    defer s.deinit();
    try s.pump(store.store());
    store.delay_write = true;
    store.pending = true;
    s.set(1);
    s.save();
    try s.pump(store.store());
    s.set(2);
    s.save();
    s.set(3);
    s.save();
    try s.pump(store.store());
    try std.testing.expectEqual(@as(usize, 1), store.writes);
    store.pending = false;
    try s.pump(store.store());
    try s.pump(store.store());
    try std.testing.expectEqual(@as(usize, 2), store.writes);
    try std.testing.expectEqualStrings("3", store.data[0..store.len]);
}
