//! Sparse Set
//!
//! O(1) lookup, insert, remove with cache-friendly iteration.
//! Used for entity -> physics body mappings and other fast lookups.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        sparse: []?u32,
        dense_keys: []u64,
        dense_values: []T,
        count: usize,
        capacity: usize,
        max_key: usize,

        pub fn init(allocator: Allocator, max_keys: usize, initial_capacity: usize) !Self {
            const sparse = try allocator.alloc(?u32, max_keys);
            errdefer allocator.free(sparse);
            @memset(sparse, null);

            const dense_keys = try allocator.alloc(u64, initial_capacity);
            errdefer allocator.free(dense_keys);

            const dense_values = try allocator.alloc(T, initial_capacity);

            return Self{
                .allocator = allocator,
                .sparse = sparse,
                .dense_keys = dense_keys,
                .dense_values = dense_values,
                .count = 0,
                .capacity = initial_capacity,
                .max_key = max_keys,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.sparse);
            self.allocator.free(self.dense_keys);
            self.allocator.free(self.dense_values);
        }

        pub fn put(self: *Self, key: u64, value: T) !void {
            if (key >= self.max_key) return error.KeyOutOfRange;

            if (self.sparse[key]) |idx| {
                self.dense_values[idx] = value;
                return;
            }

            if (self.count >= self.capacity) {
                const new_cap = self.capacity * 2;
                self.dense_keys = try self.allocator.realloc(self.dense_keys, new_cap);
                self.dense_values = self.allocator.realloc(self.dense_values, new_cap) catch |err| {
                    self.dense_keys = self.allocator.realloc(self.dense_keys, self.capacity) catch self.dense_keys;
                    return err;
                };
                self.capacity = new_cap;
            }

            const idx: u32 = @intCast(self.count);
            self.sparse[key] = idx;
            self.dense_keys[idx] = key;
            self.dense_values[idx] = value;
            self.count += 1;
        }

        pub fn get(self: *const Self, key: u64) ?T {
            if (key >= self.max_key) return null;
            const idx = self.sparse[key] orelse return null;
            return self.dense_values[idx];
        }

        pub fn getPtr(self: *Self, key: u64) ?*T {
            if (key >= self.max_key) return null;
            const idx = self.sparse[key] orelse return null;
            return &self.dense_values[idx];
        }

        pub fn contains(self: *const Self, key: u64) bool {
            if (key >= self.max_key) return false;
            return self.sparse[key] != null;
        }

        pub fn remove(self: *Self, key: u64) void {
            if (key >= self.max_key) return;
            const idx = self.sparse[key] orelse return;

            const last_idx = self.count - 1;
            if (idx != last_idx) {
                const last_key = self.dense_keys[last_idx];
                self.dense_keys[idx] = last_key;
                self.dense_values[idx] = self.dense_values[last_idx];
                self.sparse[last_key] = idx;
            }

            self.sparse[key] = null;
            self.count -= 1;
        }

        pub fn clear(self: *Self) void {
            for (self.dense_keys[0..self.count]) |key| {
                self.sparse[key] = null;
            }
            self.count = 0;
        }

        pub fn values(self: *const Self) []const T {
            return self.dense_values[0..self.count];
        }

        pub fn keys(self: *const Self) []const u64 {
            return self.dense_keys[0..self.count];
        }

        pub const Entry = struct { key: u64, value: *T };

        pub fn iterator(self: *Self) Iterator {
            return .{ .set = self, .index = 0 };
        }

        pub const Iterator = struct {
            set: *Self,
            index: usize,

            pub fn next(self: *Iterator) ?Entry {
                if (self.index >= self.set.count) return null;
                const entry = Entry{
                    .key = self.set.dense_keys[self.index],
                    .value = &self.set.dense_values[self.index],
                };
                self.index += 1;
                return entry;
            }
        };

        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

