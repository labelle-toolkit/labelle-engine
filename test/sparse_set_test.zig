const std = @import("std");

const engine = @import("engine");
const SparseSet = engine.SparseSet;

test "SparseSet basic operations" {
    const allocator = std.testing.allocator;

    var set = try SparseSet(u64).init(allocator, 1000, 16);
    defer set.deinit();

    try set.put(5, 500);
    try set.put(10, 1000);
    try set.put(3, 300);

    try std.testing.expectEqual(@as(?u64, 500), set.get(5));
    try std.testing.expectEqual(@as(?u64, 1000), set.get(10));
    try std.testing.expectEqual(@as(?u64, null), set.get(999));

    try std.testing.expect(set.contains(5));
    try std.testing.expect(!set.contains(999));

    try set.put(5, 555);
    try std.testing.expectEqual(@as(?u64, 555), set.get(5));

    set.remove(10);
    try std.testing.expect(!set.contains(10));
    try std.testing.expectEqual(@as(usize, 2), set.len());
}

test "SparseSet iteration after remove" {
    const allocator = std.testing.allocator;

    var set = try SparseSet(u32).init(allocator, 100, 16);
    defer set.deinit();

    try set.put(1, 10);
    try set.put(2, 20);
    try set.put(3, 30);
    try set.put(4, 40);

    set.remove(2);

    var sum: u32 = 0;
    for (set.values()) |v| {
        sum += v;
    }
    try std.testing.expectEqual(@as(u32, 80), sum);
}
