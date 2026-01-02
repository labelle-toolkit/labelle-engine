//! Physics Storage Benchmark
//!
//! Compares HashMap vs SparseSet vs ECS Component storage for entity->body mappings.
//! Run with: zig build-exe storage_benchmark.zig -OReleaseFast && ./storage_benchmark

const std = @import("std");

// Mock BodyId for benchmarking
const BodyId = u64;

// ============================================================================
// Option 1: Sparse Set
// ============================================================================

pub const SparseSet = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    sparse: []?u32,       // entity_id -> dense_index
    dense: []u64,         // dense_index -> entity_id
    data: []BodyId,       // dense_index -> body_id
    count: usize,
    capacity: usize,
    max_entity: usize,

    pub fn init(allocator: std.mem.Allocator, max_entities: usize, initial_capacity: usize) !Self {
        const sparse = try allocator.alloc(?u32, max_entities);
        @memset(sparse, null);

        return Self{
            .allocator = allocator,
            .sparse = sparse,
            .dense = try allocator.alloc(u64, initial_capacity),
            .data = try allocator.alloc(BodyId, initial_capacity),
            .count = 0,
            .capacity = initial_capacity,
            .max_entity = max_entities,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sparse);
        self.allocator.free(self.dense);
        self.allocator.free(self.data);
    }

    pub fn insert(self: *Self, entity: u64, body_id: BodyId) !void {
        if (entity >= self.max_entity) return error.EntityOutOfRange;

        // Already exists - update
        if (self.sparse[entity]) |idx| {
            self.data[idx] = body_id;
            return;
        }

        // Grow if needed
        if (self.count >= self.capacity) {
            const new_cap = self.capacity * 2;
            self.dense = try self.allocator.realloc(self.dense, new_cap);
            self.data = try self.allocator.realloc(self.data, new_cap);
            self.capacity = new_cap;
        }

        const idx: u32 = @intCast(self.count);
        self.sparse[entity] = idx;
        self.dense[idx] = entity;
        self.data[idx] = body_id;
        self.count += 1;
    }

    pub fn get(self: *const Self, entity: u64) ?BodyId {
        if (entity >= self.max_entity) return null;
        const idx = self.sparse[entity] orelse return null;
        return self.data[idx];
    }

    pub fn contains(self: *const Self, entity: u64) bool {
        if (entity >= self.max_entity) return false;
        return self.sparse[entity] != null;
    }

    pub fn remove(self: *Self, entity: u64) void {
        if (entity >= self.max_entity) return;
        const idx = self.sparse[entity] orelse return;

        // Swap with last element
        const last_idx = self.count - 1;
        if (idx != last_idx) {
            const last_entity = self.dense[last_idx];
            self.dense[idx] = last_entity;
            self.data[idx] = self.data[last_idx];
            self.sparse[last_entity] = idx;
        }

        self.sparse[entity] = null;
        self.count -= 1;
    }

    // Iterator for cache-friendly iteration
    pub fn iterate(self: *const Self) []const BodyId {
        return self.data[0..self.count];
    }

    pub fn iterateEntities(self: *const Self) []const u64 {
        return self.dense[0..self.count];
    }
};

// ============================================================================
// Option 2: Mock ECS Component Storage (simulates zig_ecs behavior)
// ============================================================================

pub const EcsComponentStorage = struct {
    const Self = @This();

    // Simulates ECS component storage with sparse set internally
    // This is what zig_ecs uses under the hood
    inner: SparseSet,

    pub fn init(allocator: std.mem.Allocator, max_entities: usize, initial_capacity: usize) !Self {
        return Self{
            .inner = try SparseSet.init(allocator, max_entities, initial_capacity),
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    // ECS-style API
    pub fn set(self: *Self, entity: u64, body_id: BodyId) !void {
        try self.inner.insert(entity, body_id);
    }

    pub fn get(self: *const Self, entity: u64) ?BodyId {
        return self.inner.get(entity);
    }

    pub fn tryGet(self: *const Self, entity: u64) ?*const BodyId {
        if (entity >= self.inner.max_entity) return null;
        const idx = self.inner.sparse[entity] orelse return null;
        return &self.inner.data[idx];
    }

    pub fn remove(self: *Self, entity: u64) void {
        self.inner.remove(entity);
    }

    pub fn iterate(self: *const Self) []const BodyId {
        return self.inner.iterate();
    }
};

// ============================================================================
// HashMap (baseline for comparison)
// ============================================================================

pub const HashMapStorage = struct {
    const Self = @This();

    map: std.AutoHashMap(u64, BodyId),

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .map = std.AutoHashMap(u64, BodyId).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }

    pub fn insert(self: *Self, entity: u64, body_id: BodyId) !void {
        try self.map.put(entity, body_id);
    }

    pub fn get(self: *const Self, entity: u64) ?BodyId {
        return self.map.get(entity);
    }

    pub fn contains(self: *const Self, entity: u64) bool {
        return self.map.contains(entity);
    }

    pub fn remove(self: *Self, entity: u64) void {
        _ = self.map.remove(entity);
    }
};

// ============================================================================
// Benchmarks
// ============================================================================

const WARMUP_ITERATIONS = 100;
const BENCH_ITERATIONS = 1000;
const ENTITY_COUNTS = [_]usize{ 100, 1000, 10000, 50000 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  Physics Storage Benchmark: HashMap vs SparseSet vs ECS\n", .{});
    std.debug.print("============================================================\n\n", .{});

    for (ENTITY_COUNTS) |entity_count| {
        std.debug.print("--- {} entities ---\n\n", .{entity_count});

        try benchInsert(allocator, entity_count);
        try benchLookup(allocator, entity_count);
        try benchIteration(allocator, entity_count);
        try benchRemove(allocator, entity_count);
        try benchMixedWorkload(allocator, entity_count);

        std.debug.print("\n", .{});
    }
}

fn benchInsert(allocator: std.mem.Allocator, entity_count: usize) !void {
    std.debug.print("INSERT ({} entities):\n", .{entity_count});

    // HashMap
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = HashMapStorage.init(allocator);
            defer storage.deinit();

            var timer = try std.time.Timer.start();
            for (0..entity_count) |i| {
                try storage.insert(@intCast(i), @intCast(i * 100));
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  HashMap:   {d:>8.2} us  ({d:.0} inserts/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }

    // SparseSet
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = try SparseSet.init(allocator, entity_count + 1000, 256);
            defer storage.deinit();

            var timer = try std.time.Timer.start();
            for (0..entity_count) |i| {
                try storage.insert(@intCast(i), @intCast(i * 100));
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  SparseSet: {d:>8.2} us  ({d:.0} inserts/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }

    // ECS Component
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = try EcsComponentStorage.init(allocator, entity_count + 1000, 256);
            defer storage.deinit();

            var timer = try std.time.Timer.start();
            for (0..entity_count) |i| {
                try storage.set(@intCast(i), @intCast(i * 100));
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  ECS:       {d:>8.2} us  ({d:.0} inserts/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }
}

fn benchLookup(allocator: std.mem.Allocator, entity_count: usize) !void {
    std.debug.print("LOOKUP ({} random lookups):\n", .{entity_count * 10});

    // Pre-generate random lookup order
    var rng = std.Random.DefaultPrng.init(42);
    const lookup_order = try allocator.alloc(u64, entity_count * 10);
    defer allocator.free(lookup_order);
    for (lookup_order) |*id| {
        id.* = rng.random().uintLessThan(u64, entity_count);
    }

    // HashMap
    {
        var storage = HashMapStorage.init(allocator);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            for (lookup_order) |entity| {
                checksum +%= storage.get(entity) orelse 0;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  HashMap:   {d:>8.2} us  ({d:.0} lookups/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(lookup_order.len)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }

    // SparseSet
    {
        var storage = try SparseSet.init(allocator, entity_count + 1000, 256);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            for (lookup_order) |entity| {
                checksum +%= storage.get(entity) orelse 0;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  SparseSet: {d:>8.2} us  ({d:.0} lookups/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(lookup_order.len)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }

    // ECS Component
    {
        var storage = try EcsComponentStorage.init(allocator, entity_count + 1000, 256);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.set(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            for (lookup_order) |entity| {
                checksum +%= storage.get(entity) orelse 0;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  ECS:       {d:>8.2} us  ({d:.0} lookups/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(lookup_order.len)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }
}

fn benchIteration(allocator: std.mem.Allocator, entity_count: usize) !void {
    std.debug.print("ITERATION (sum all body IDs):\n", .{});

    // HashMap
    {
        var storage = HashMapStorage.init(allocator);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            var iter = storage.map.valueIterator();
            while (iter.next()) |v| {
                checksum +%= v.*;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  HashMap:   {d:>8.2} us  ({d:.0} items/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }

    // SparseSet
    {
        var storage = try SparseSet.init(allocator, entity_count + 1000, 256);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            for (storage.iterate()) |body_id| {
                checksum +%= body_id;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  SparseSet: {d:>8.2} us  ({d:.0} items/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }

    // ECS Component
    {
        var storage = try EcsComponentStorage.init(allocator, entity_count + 1000, 256);
        defer storage.deinit();
        for (0..entity_count) |i| {
            try storage.set(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var checksum: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var timer = try std.time.Timer.start();
            for (storage.iterate()) |body_id| {
                checksum +%= body_id;
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  ECS:       {d:>8.2} us  ({d:.0} items/us) [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
            checksum % 1000,
        });
    }
}

fn benchRemove(allocator: std.mem.Allocator, entity_count: usize) !void {
    std.debug.print("REMOVE (remove half the entities):\n", .{});

    const remove_count = entity_count / 2;

    // HashMap
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = HashMapStorage.init(allocator);
            defer storage.deinit();
            for (0..entity_count) |i| {
                try storage.insert(@intCast(i), @intCast(i * 100));
            }

            var timer = try std.time.Timer.start();
            for (0..remove_count) |i| {
                storage.remove(@intCast(i * 2)); // Remove even entities
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  HashMap:   {d:>8.2} us  ({d:.0} removes/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(remove_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }

    // SparseSet
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = try SparseSet.init(allocator, entity_count + 1000, 256);
            defer storage.deinit();
            for (0..entity_count) |i| {
                try storage.insert(@intCast(i), @intCast(i * 100));
            }

            var timer = try std.time.Timer.start();
            for (0..remove_count) |i| {
                storage.remove(@intCast(i * 2));
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  SparseSet: {d:>8.2} us  ({d:.0} removes/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(remove_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }

    // ECS Component
    {
        var total_ns: u64 = 0;
        for (0..BENCH_ITERATIONS) |_| {
            var storage = try EcsComponentStorage.init(allocator, entity_count + 1000, 256);
            defer storage.deinit();
            for (0..entity_count) |i| {
                try storage.set(@intCast(i), @intCast(i * 100));
            }

            var timer = try std.time.Timer.start();
            for (0..remove_count) |i| {
                storage.remove(@intCast(i * 2));
            }
            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  ECS:       {d:>8.2} us  ({d:.0} removes/us)\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            @as(f64, @floatFromInt(remove_count)) / (@as(f64, @floatFromInt(avg_ns)) / 1000),
        });
    }
}

fn benchMixedWorkload(allocator: std.mem.Allocator, entity_count: usize) !void {
    std.debug.print("MIXED (insert, lookup, remove cycle):\n", .{});

    const ops_per_cycle = entity_count / 10;

    // HashMap
    {
        var storage = HashMapStorage.init(allocator);
        defer storage.deinit();

        // Pre-populate
        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var next_entity: u64 = entity_count;
        var checksum: u64 = 0;

        for (0..BENCH_ITERATIONS) |iter| {
            var timer = try std.time.Timer.start();

            // Lookups
            for (0..ops_per_cycle) |i| {
                const lookup_id: u64 = (i + iter * 7) % entity_count;
                checksum +%= storage.get(lookup_id) orelse 0;
            }

            // Removes
            for (0..ops_per_cycle / 2) |i| {
                const remove_id: u64 = (i + iter * 13) % entity_count;
                storage.remove(remove_id);
            }

            // Inserts
            for (0..ops_per_cycle / 2) |_| {
                try storage.insert(next_entity, next_entity * 100);
                next_entity += 1;
            }

            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  HashMap:   {d:>8.2} us  [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            checksum % 1000,
        });
    }

    // SparseSet
    {
        const max_entities = entity_count + BENCH_ITERATIONS * ops_per_cycle;
        var storage = try SparseSet.init(allocator, max_entities, 256);
        defer storage.deinit();

        for (0..entity_count) |i| {
            try storage.insert(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var next_entity: u64 = entity_count;
        var checksum: u64 = 0;

        for (0..BENCH_ITERATIONS) |iter| {
            var timer = try std.time.Timer.start();

            for (0..ops_per_cycle) |i| {
                const lookup_id: u64 = (i + iter * 7) % entity_count;
                checksum +%= storage.get(lookup_id) orelse 0;
            }

            for (0..ops_per_cycle / 2) |i| {
                const remove_id: u64 = (i + iter * 13) % entity_count;
                storage.remove(remove_id);
            }

            for (0..ops_per_cycle / 2) |_| {
                try storage.insert(next_entity, next_entity * 100);
                next_entity += 1;
            }

            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  SparseSet: {d:>8.2} us  [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            checksum % 1000,
        });
    }

    // ECS Component
    {
        const max_entities = entity_count + BENCH_ITERATIONS * ops_per_cycle;
        var storage = try EcsComponentStorage.init(allocator, max_entities, 256);
        defer storage.deinit();

        for (0..entity_count) |i| {
            try storage.set(@intCast(i), @intCast(i * 100));
        }

        var total_ns: u64 = 0;
        var next_entity: u64 = entity_count;
        var checksum: u64 = 0;

        for (0..BENCH_ITERATIONS) |iter| {
            var timer = try std.time.Timer.start();

            for (0..ops_per_cycle) |i| {
                const lookup_id: u64 = (i + iter * 7) % entity_count;
                checksum +%= storage.get(lookup_id) orelse 0;
            }

            for (0..ops_per_cycle / 2) |i| {
                const remove_id: u64 = (i + iter * 13) % entity_count;
                storage.remove(remove_id);
            }

            for (0..ops_per_cycle / 2) |_| {
                try storage.set(next_entity, next_entity * 100);
                next_entity += 1;
            }

            total_ns += timer.read();
        }
        const avg_ns = total_ns / BENCH_ITERATIONS;
        std.debug.print("  ECS:       {d:>8.2} us  [checksum: {}]\n", .{
            @as(f64, @floatFromInt(avg_ns)) / 1000,
            checksum % 1000,
        });
    }
}
