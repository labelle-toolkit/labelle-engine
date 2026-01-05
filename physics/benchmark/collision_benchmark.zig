//! Collision Query Pattern Benchmark
//!
//! Compares different approaches for storing and querying collision state:
//! - Option A: Touching component (dense storage, fast iteration)
//! - Option B: CollisionPair storage (sparse, central registry)
//! - Option C: Bitmask approach (compact, limited entities)
//!
//! Run with: zig build bench-collision (in physics directory)

const std = @import("std");
const physics = @import("labelle-physics");
const PhysicsWorld = physics.PhysicsWorld;
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;

const Timer = std.time.Timer;

const ENTITY_COUNT: usize = 1_000;
const COLLISION_PAIRS: usize = 5_000;
const ITERATIONS: usize = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         Collision Query Pattern Benchmark                    ║\n", .{});
    std.debug.print("║         {} entities, {} pairs, {} iterations          ║\n", .{ ENTITY_COUNT, COLLISION_PAIRS, ITERATIONS });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Run benchmarks
    const results_a = try benchOptionA(allocator);
    const results_b = try benchOptionB(allocator);
    const results_c = try benchOptionC(allocator);

    // Print summary
    printSummary(results_a, results_b, results_c);
}

const BenchResults = struct {
    add_collision_ns: u64,
    remove_collision_ns: u64,
    query_touching_ns: u64,
    iterate_all_ns: u64,
    memory_bytes: usize,
};

/// Option A: Touching component on each entity
/// Each entity has a component listing what it's touching
fn benchOptionA(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option A: Touching Component ━━━\n", .{});

    const Touching = struct {
        entities: std.ArrayListUnmanaged(u64) = .{},

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.entities.deinit(alloc);
        }

        fn add(self: *@This(), alloc: std.mem.Allocator, entity: u64) !void {
            // Check if already present
            for (self.entities.items) |e| {
                if (e == entity) return;
            }
            try self.entities.append(alloc, entity);
        }

        fn remove(self: *@This(), entity: u64) void {
            for (self.entities.items, 0..) |e, i| {
                if (e == entity) {
                    _ = self.entities.swapRemove(i);
                    return;
                }
            }
        }

        fn isTouching(self: *const @This(), entity: u64) bool {
            for (self.entities.items) |e| {
                if (e == entity) return true;
            }
            return false;
        }
    };

    // Storage: one Touching component per entity
    var components = try allocator.alloc(Touching, ENTITY_COUNT);
    defer {
        for (components) |*c| c.deinit(allocator);
        allocator.free(components);
    }

    for (components) |*c| {
        c.* = Touching{};
    }

    // Generate random collision pairs
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const pairs = try allocator.alloc([2]u64, COLLISION_PAIRS);
    defer allocator.free(pairs);

    for (pairs) |*pair| {
        pair[0] = random.intRangeLessThan(u64, 0, ENTITY_COUNT);
        pair[1] = random.intRangeLessThan(u64, 0, ENTITY_COUNT);
        if (pair[0] == pair[1]) pair[1] = (pair[1] + 1) % ENTITY_COUNT;
    }

    var timer = try Timer.start();

    // Benchmark add collision
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            try components[pair[0]].add(allocator, pair[1]);
            try components[pair[1]].add(allocator, pair[0]);
        }
    }
    const add_ns = timer.read();

    // Benchmark query touching
    timer.reset();
    var found: usize = 0;
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            if (components[pair[0]].isTouching(pair[1])) {
                found += 1;
            }
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&found);

    // Benchmark iterate all collisions
    timer.reset();
    var count: usize = 0;
    for (0..ITERATIONS) |_| {
        for (components) |*c| {
            count += c.entities.items.len;
        }
    }
    const iterate_ns = timer.read();
    std.mem.doNotOptimizeAway(&count);

    // Benchmark remove collision
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            components[pair[0]].remove(pair[1]);
            components[pair[1]].remove(pair[0]);
        }
    }
    const remove_ns = timer.read();

    // Calculate memory
    var total_mem: usize = ENTITY_COUNT * @sizeOf(Touching);
    for (components) |*c| {
        total_mem += c.entities.capacity * @sizeOf(u64);
    }

    const results = BenchResults{
        .add_collision_ns = add_ns,
        .remove_collision_ns = remove_ns,
        .query_touching_ns = query_ns,
        .iterate_all_ns = iterate_ns,
        .memory_bytes = total_mem,
    };

    printResults("Option A", results);
    return results;
}

/// Option B: Central CollisionPair registry
/// All collision pairs stored in a central hash set
fn benchOptionB(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option B: Central CollisionPair Registry ━━━\n", .{});

    const CollisionPair = struct {
        a: u64,
        b: u64,

        // Normalize so a < b for consistent hashing
        fn normalized(self: @This()) @This() {
            return if (self.a < self.b)
                self
            else
                .{ .a = self.b, .b = self.a };
        }
    };

    const PairContext = struct {
        pub fn hash(_: @This(), key: CollisionPair) u64 {
            const n = key.normalized();
            return @as(u64, @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&n))));
        }

        pub fn eql(_: @This(), a: CollisionPair, b: CollisionPair) bool {
            const na = a.normalized();
            const nb = b.normalized();
            return na.a == nb.a and na.b == nb.b;
        }
    };

    var registry = std.HashMap(CollisionPair, void, PairContext, 80).init(allocator);
    defer registry.deinit();

    // Generate random collision pairs
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const pairs = try allocator.alloc(CollisionPair, COLLISION_PAIRS);
    defer allocator.free(pairs);

    for (pairs) |*pair| {
        pair.a = random.intRangeLessThan(u64, 0, ENTITY_COUNT);
        pair.b = random.intRangeLessThan(u64, 0, ENTITY_COUNT);
        if (pair.a == pair.b) pair.b = (pair.b + 1) % ENTITY_COUNT;
    }

    var timer = try Timer.start();

    // Benchmark add collision
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            try registry.put(pair, {});
        }
    }
    const add_ns = timer.read();

    // Benchmark query touching
    timer.reset();
    var found: usize = 0;
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            if (registry.contains(pair)) {
                found += 1;
            }
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&found);

    // Benchmark iterate all collisions
    timer.reset();
    var count: usize = 0;
    for (0..ITERATIONS) |_| {
        var iter = registry.iterator();
        while (iter.next()) |_| {
            count += 1;
        }
    }
    const iterate_ns = timer.read();
    std.mem.doNotOptimizeAway(&count);

    // Benchmark remove collision
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (pairs) |pair| {
            _ = registry.remove(pair);
        }
    }
    const remove_ns = timer.read();

    const results = BenchResults{
        .add_collision_ns = add_ns,
        .remove_collision_ns = remove_ns,
        .query_touching_ns = query_ns,
        .iterate_all_ns = iterate_ns,
        .memory_bytes = registry.capacity() * (@sizeOf(CollisionPair) + @sizeOf(void) + @sizeOf(u64)),
    };

    printResults("Option B", results);
    return results;
}

/// Option C: Bitmask approach
/// Each entity has a bitmask of what it's touching (limited to 64 entities for demo)
fn benchOptionC(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option C: Bitmask Approach ━━━\n", .{});

    // For this benchmark, we use a smaller entity count that fits in bitmask
    const BITMASK_ENTITIES: usize = 64;
    const BITMASK_PAIRS: usize = 200;

    const masks = try allocator.alloc(u64, BITMASK_ENTITIES);
    defer allocator.free(masks);

    for (masks) |*m| {
        m.* = 0;
    }

    // Generate random collision pairs within bitmask range
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const pairs = try allocator.alloc([2]u6, BITMASK_PAIRS);
    defer allocator.free(pairs);

    for (pairs) |*pair| {
        pair[0] = random.int(u6);
        pair[1] = random.int(u6);
        if (pair[0] == pair[1]) pair[1] = pair[1] +% 1;
    }

    var timer = try Timer.start();

    // Benchmark add collision (scaled iterations for comparable work)
    const scaled_iterations = ITERATIONS * (COLLISION_PAIRS / BITMASK_PAIRS);

    timer.reset();
    for (0..scaled_iterations) |_| {
        for (pairs) |pair| {
            masks[pair[0]] |= @as(u64, 1) << pair[1];
            masks[pair[1]] |= @as(u64, 1) << pair[0];
        }
    }
    const add_ns = timer.read();

    // Benchmark query touching
    timer.reset();
    var found: usize = 0;
    for (0..scaled_iterations) |_| {
        for (pairs) |pair| {
            if (masks[pair[0]] & (@as(u64, 1) << pair[1]) != 0) {
                found += 1;
            }
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&found);

    // Benchmark iterate all collisions
    timer.reset();
    var count: usize = 0;
    for (0..scaled_iterations) |_| {
        for (masks) |mask| {
            count += @popCount(mask);
        }
    }
    const iterate_ns = timer.read();
    std.mem.doNotOptimizeAway(&count);

    // Benchmark remove collision
    timer.reset();
    for (0..scaled_iterations) |_| {
        for (pairs) |pair| {
            masks[pair[0]] &= ~(@as(u64, 1) << pair[1]);
            masks[pair[1]] &= ~(@as(u64, 1) << pair[0]);
        }
    }
    const remove_ns = timer.read();

    const results = BenchResults{
        .add_collision_ns = add_ns,
        .remove_collision_ns = remove_ns,
        .query_touching_ns = query_ns,
        .iterate_all_ns = iterate_ns,
        .memory_bytes = BITMASK_ENTITIES * @sizeOf(u64),
    };

    printResults("Option C", results);
    std.debug.print("    Note: Limited to 64 entities per bitmask\n\n", .{});
    return results;
}

fn printResults(name: []const u8, r: BenchResults) void {
    std.debug.print("  {s}:\n", .{name});
    std.debug.print("    Add collision:    {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.add_collision_ns)) / 1_000_000,
    });
    std.debug.print("    Remove collision: {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.remove_collision_ns)) / 1_000_000,
    });
    std.debug.print("    Query touching:   {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.query_touching_ns)) / 1_000_000,
    });
    std.debug.print("    Iterate all:      {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.iterate_all_ns)) / 1_000_000,
    });
    std.debug.print("    Memory:           {d:.1} KB\n", .{
        @as(f64, @floatFromInt(r.memory_bytes)) / 1024,
    });
    std.debug.print("\n", .{});
}

fn printSummary(a: BenchResults, b: BenchResults, c: BenchResults) void {
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         SUMMARY                              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    const add_fastest = @min(@min(a.add_collision_ns, b.add_collision_ns), c.add_collision_ns);
    const remove_fastest = @min(@min(a.remove_collision_ns, b.remove_collision_ns), c.remove_collision_ns);
    const query_fastest = @min(@min(a.query_touching_ns, b.query_touching_ns), c.query_touching_ns);
    const iterate_fastest = @min(@min(a.iterate_all_ns, b.iterate_all_ns), c.iterate_all_ns);

    std.debug.print("║ Add Collision:                                               ║\n", .{});
    printCompare("  A (Touching)", a.add_collision_ns, add_fastest);
    printCompare("  B (Central)", b.add_collision_ns, add_fastest);
    printCompare("  C (Bitmask)", c.add_collision_ns, add_fastest);

    std.debug.print("║ Remove Collision:                                            ║\n", .{});
    printCompare("  A (Touching)", a.remove_collision_ns, remove_fastest);
    printCompare("  B (Central)", b.remove_collision_ns, remove_fastest);
    printCompare("  C (Bitmask)", c.remove_collision_ns, remove_fastest);

    std.debug.print("║ Query Touching:                                              ║\n", .{});
    printCompare("  A (Touching)", a.query_touching_ns, query_fastest);
    printCompare("  B (Central)", b.query_touching_ns, query_fastest);
    printCompare("  C (Bitmask)", c.query_touching_ns, query_fastest);

    std.debug.print("║ Iterate All:                                                 ║\n", .{});
    printCompare("  A (Touching)", a.iterate_all_ns, iterate_fastest);
    printCompare("  B (Central)", b.iterate_all_ns, iterate_fastest);
    printCompare("  C (Bitmask)", c.iterate_all_ns, iterate_fastest);

    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Memory comparison
    std.debug.print("║ Memory Usage:                                                ║\n", .{});
    std.debug.print("║   A (Touching):     {d:>8.1} KB                              ║\n", .{@as(f64, @floatFromInt(a.memory_bytes)) / 1024});
    std.debug.print("║   B (Central):      {d:>8.1} KB                              ║\n", .{@as(f64, @floatFromInt(b.memory_bytes)) / 1024});
    std.debug.print("║   C (Bitmask):      {d:>8.1} KB (64 entity limit)            ║\n", .{@as(f64, @floatFromInt(c.memory_bytes)) / 1024});

    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Determine winner
    var a_wins: u32 = 0;
    var b_wins: u32 = 0;
    var c_wins: u32 = 0;

    if (a.add_collision_ns == add_fastest) a_wins += 1;
    if (b.add_collision_ns == add_fastest) b_wins += 1;
    if (c.add_collision_ns == add_fastest) c_wins += 1;

    if (a.remove_collision_ns == remove_fastest) a_wins += 1;
    if (b.remove_collision_ns == remove_fastest) b_wins += 1;
    if (c.remove_collision_ns == remove_fastest) c_wins += 1;

    if (a.query_touching_ns == query_fastest) a_wins += 1;
    if (b.query_touching_ns == query_fastest) b_wins += 1;
    if (c.query_touching_ns == query_fastest) c_wins += 1;

    if (a.iterate_all_ns == iterate_fastest) a_wins += 1;
    if (b.iterate_all_ns == iterate_fastest) b_wins += 1;
    if (c.iterate_all_ns == iterate_fastest) c_wins += 1;

    const winner = if (a_wins >= b_wins and a_wins >= c_wins)
        "Option A (Touching Component)"
    else if (b_wins >= c_wins)
        "Option B (Central Registry)"
    else
        "Option C (Bitmask - 64 entity limit)";

    std.debug.print("║ RECOMMENDED: {s:<47} ║\n", .{winner});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
}

fn printCompare(name: []const u8, time_ns: u64, fastest_ns: u64) void {
    const time_ms = @as(f64, @floatFromInt(time_ns)) / 1_000_000;
    const ratio = @as(f64, @floatFromInt(time_ns)) / @as(f64, @floatFromInt(fastest_ns));

    if (time_ns == fastest_ns) {
        std.debug.print("║   {s:<18} {d:>8.2}ms  [FASTEST]                    ║\n", .{ name, time_ms });
    } else {
        std.debug.print("║   {s:<18} {d:>8.2}ms  ({d:.2}x slower)                ║\n", .{ name, time_ms, ratio });
    }
}
