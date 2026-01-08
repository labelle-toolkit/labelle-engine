//! Sparse Set
//!
//! O(1) lookup, insert, remove with cache-friendly iteration.
//! Used for entity -> physics body mappings.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic sparse set for mapping u64 keys to values of type T
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        sparse: []?u32,      // key -> dense_index
        dense_keys: []u64,   // dense_index -> key
        dense_values: []T,   // dense_index -> value
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

        /// Insert or update a key-value pair
        pub fn put(self: *Self, key: u64, value: T) !void {
            if (key >= self.max_key) return error.KeyOutOfRange;

            // Update existing
            if (self.sparse[key]) |idx| {
                self.dense_values[idx] = value;
                return;
            }

            // Grow if needed
            if (self.count >= self.capacity) {
                const new_cap = self.capacity * 2;
                self.dense_keys = try self.allocator.realloc(self.dense_keys, new_cap);
                self.dense_values = try self.allocator.realloc(self.dense_values, new_cap);
                self.capacity = new_cap;
            }

            const idx: u32 = @intCast(self.count);
            self.sparse[key] = idx;
            self.dense_keys[idx] = key;
            self.dense_values[idx] = value;
            self.count += 1;
        }

        /// Get value for key
        pub fn get(self: *const Self, key: u64) ?T {
            if (key >= self.max_key) return null;
            const idx = self.sparse[key] orelse return null;
            return self.dense_values[idx];
        }

        /// Get pointer to value for key
        pub fn getPtr(self: *Self, key: u64) ?*T {
            if (key >= self.max_key) return null;
            const idx = self.sparse[key] orelse return null;
            return &self.dense_values[idx];
        }

        /// Check if key exists
        pub fn contains(self: *const Self, key: u64) bool {
            if (key >= self.max_key) return false;
            return self.sparse[key] != null;
        }

        /// Remove key-value pair
        pub fn remove(self: *Self, key: u64) void {
            if (key >= self.max_key) return;
            const idx = self.sparse[key] orelse return;

            // Swap with last element
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

        /// Clear all entries
        pub fn clear(self: *Self) void {
            for (self.dense_keys[0..self.count]) |key| {
                self.sparse[key] = null;
            }
            self.count = 0;
        }

        /// Iterate over all values (cache-friendly)
        pub fn values(self: *const Self) []const T {
            return self.dense_values[0..self.count];
        }

        /// Iterate over all keys
        pub fn keys(self: *const Self) []const u64 {
            return self.dense_keys[0..self.count];
        }

        /// Get key-value pairs for iteration
        pub const Entry = struct {
            key: u64,
            value: *T,
        };

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

        /// Number of entries
        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

// Tests
test "SparseSet basic operations" {
    const allocator = std.testing.allocator;

    var set = try SparseSet(u64).init(allocator, 1000, 16);
    defer set.deinit();

    // Insert
    try set.put(5, 500);
    try set.put(10, 1000);
    try set.put(3, 300);

    // Get
    try std.testing.expectEqual(@as(?u64, 500), set.get(5));
    try std.testing.expectEqual(@as(?u64, 1000), set.get(10));
    try std.testing.expectEqual(@as(?u64, 300), set.get(3));
    try std.testing.expectEqual(@as(?u64, null), set.get(999));

    // Contains
    try std.testing.expect(set.contains(5));
    try std.testing.expect(!set.contains(999));

    // Update
    try set.put(5, 555);
    try std.testing.expectEqual(@as(?u64, 555), set.get(5));

    // Remove
    set.remove(10);
    try std.testing.expect(!set.contains(10));
    try std.testing.expectEqual(@as(usize, 2), set.len());

    // Iteration
    var sum: u64 = 0;
    for (set.values()) |v| {
        sum += v;
    }
    try std.testing.expectEqual(@as(u64, 855), sum); // 555 + 300
}

test "SparseSet iteration order stable after remove" {
    const allocator = std.testing.allocator;

    var set = try SparseSet(u32).init(allocator, 100, 16);
    defer set.deinit();

    try set.put(1, 10);
    try set.put(2, 20);
    try set.put(3, 30);
    try set.put(4, 40);

    // Remove middle element
    set.remove(2);

    // Should still iterate all remaining
    var sum: u32 = 0;
    for (set.values()) |v| {
        sum += v;
    }
    try std.testing.expectEqual(@as(u32, 80), sum); // 10 + 30 + 40
}
