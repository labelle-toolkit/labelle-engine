//! Compound Shapes Benchmark
//!
//! Compares different approaches for entities with multiple collision shapes:
//! - Option A: Multiple Collider components per entity (ECS query per shape)
//! - Option B: Collider with shapes array (single component, multiple shapes)
//! - Option C: Child entities approach (hierarchy of single-shape entities)
//!
//! Run with: zig build bench-compound (in physics directory)

const std = @import("std");
const physics = @import("labelle-physics");
const PhysicsWorld = physics.PhysicsWorld;
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;

const Timer = std.time.Timer;

const ENTITY_COUNT: usize = 1_000;
const SHAPES_PER_ENTITY: usize = 4;
const ITERATIONS: usize = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         Compound Shapes Benchmark                            ║\n", .{});
    std.debug.print("║         {} entities, {} shapes each, {} iterations       ║\n", .{ ENTITY_COUNT, SHAPES_PER_ENTITY, ITERATIONS });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Run benchmarks
    const results_a = try benchOptionA(allocator);
    const results_b = try benchOptionB(allocator);
    const results_c = try benchOptionC(allocator);

    // Print summary
    printSummary(results_a, results_b, results_c);
}

const BenchResults = struct {
    create_ns: u64,
    update_ns: u64,
    query_ns: u64,
    memory_bytes: usize,
};

/// Option A: Multiple Collider components per entity
/// Each shape is its own component, linked to parent entity
fn benchOptionA(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option A: Multiple Components ━━━\n", .{});

    // Simulate multi-component storage
    // In a real ECS, each entity could have multiple Collider components
    // We simulate with a hashmap of entity -> list of colliders
    const ColliderList = std.ArrayListUnmanaged(Collider);
    var storage = std.AutoHashMap(u64, ColliderList).init(allocator);
    defer {
        var iter = storage.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        storage.deinit();
    }

    var timer = try Timer.start();

    // Benchmark creation
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);

            var list = ColliderList{};
            for (0..SHAPES_PER_ENTITY) |shape_idx| {
                const offset_x: f32 = @as(f32, @floatFromInt(shape_idx)) * 10.0;
                try list.append(allocator, Collider{
                    .shape = .{ .box = .{ .width = 20, .height = 20 } },
                    .offset = .{ offset_x, 0 },
                });
            }
            try storage.put(entity, list);
        }

        // Clear for next iteration
        var iter = storage.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        storage.clearRetainingCapacity();
    }
    const create_ns = timer.read();

    // Recreate for subsequent tests
    for (0..ENTITY_COUNT) |entity_idx| {
        const entity: u64 = @intCast(entity_idx);
        var list = ColliderList{};
        for (0..SHAPES_PER_ENTITY) |shape_idx| {
            const offset_x: f32 = @as(f32, @floatFromInt(shape_idx)) * 10.0;
            try list.append(allocator, Collider{
                .shape = .{ .box = .{ .width = 20, .height = 20 } },
                .offset = .{ offset_x, 0 },
            });
        }
        try storage.put(entity, list);
    }

    // Benchmark update (modifying shape properties)
    timer.reset();
    for (0..ITERATIONS) |iter_idx| {
        var entity_iter = storage.iterator();
        while (entity_iter.next()) |entry| {
            for (entry.value_ptr.items) |*collider| {
                // Simulate updating offset
                collider.offset[0] += @as(f32, @floatFromInt(iter_idx % 2)) * 0.1;
            }
        }
    }
    const update_ns = timer.read();

    // Benchmark query (find all shapes for specific entities)
    timer.reset();
    var total_shapes: usize = 0;
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);
            if (storage.get(entity)) |list| {
                total_shapes += list.items.len;
            }
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&total_shapes);

    // Calculate memory
    var mem: usize = @sizeOf(@TypeOf(storage));
    var mem_iter = storage.valueIterator();
    while (mem_iter.next()) |list| {
        mem += @sizeOf(ColliderList) + list.capacity * @sizeOf(Collider);
    }

    const results = BenchResults{
        .create_ns = create_ns,
        .update_ns = update_ns,
        .query_ns = query_ns,
        .memory_bytes = mem,
    };

    printResults("Option A", results);
    return results;
}

/// Option B: Collider with shapes array
/// Single component contains all shapes
fn benchOptionB(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option B: Shapes Array in Component ━━━\n", .{});

    const CompoundCollider = struct {
        shapes: [SHAPES_PER_ENTITY]struct {
            shape_type: enum { box, circle } = .box,
            width: f32 = 20,
            height: f32 = 20,
            radius: f32 = 10,
            offset: [2]f32 = .{ 0, 0 },
        } = undefined,
        shape_count: usize = 0,
    };

    const storage = try allocator.alloc(CompoundCollider, ENTITY_COUNT);
    defer allocator.free(storage);

    var timer = try Timer.start();

    // Benchmark creation
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (storage) |*collider| {
            collider.shape_count = SHAPES_PER_ENTITY;
            for (0..SHAPES_PER_ENTITY) |shape_idx| {
                const offset_x: f32 = @as(f32, @floatFromInt(shape_idx)) * 10.0;
                collider.shapes[shape_idx] = .{
                    .shape_type = .box,
                    .width = 20,
                    .height = 20,
                    .offset = .{ offset_x, 0 },
                };
            }
        }
    }
    const create_ns = timer.read();

    // Benchmark update (modifying shape properties)
    timer.reset();
    for (0..ITERATIONS) |iter_idx| {
        for (storage) |*collider| {
            for (0..collider.shape_count) |shape_idx| {
                collider.shapes[shape_idx].offset[0] += @as(f32, @floatFromInt(iter_idx % 2)) * 0.1;
            }
        }
    }
    const update_ns = timer.read();

    // Benchmark query (access all shapes for all entities)
    timer.reset();
    var total_shapes: usize = 0;
    for (0..ITERATIONS) |_| {
        for (storage) |*collider| {
            total_shapes += collider.shape_count;
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&total_shapes);

    const results = BenchResults{
        .create_ns = create_ns,
        .update_ns = update_ns,
        .query_ns = query_ns,
        .memory_bytes = ENTITY_COUNT * @sizeOf(CompoundCollider),
    };

    printResults("Option B", results);
    return results;
}

/// Option C: Child entities approach
/// Each shape is its own entity, linked via parent reference
fn benchOptionC(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option C: Child Entities ━━━\n", .{});

    const ShapeEntity = struct {
        parent: u64,
        collider: Collider,
    };

    // Total entities = parent entities + shape entities
    const TOTAL_SHAPE_ENTITIES = ENTITY_COUNT * SHAPES_PER_ENTITY;

    const shape_entities = try allocator.alloc(ShapeEntity, TOTAL_SHAPE_ENTITIES);
    defer allocator.free(shape_entities);

    // Parent -> children lookup
    const ChildList = std.ArrayListUnmanaged(usize);
    var children_map = std.AutoHashMap(u64, ChildList).init(allocator);
    defer {
        var iter = children_map.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        children_map.deinit();
    }

    var timer = try Timer.start();

    // Benchmark creation
    timer.reset();
    for (0..ITERATIONS) |_| {
        var shape_idx: usize = 0;
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);

            var child_list = ChildList{};

            for (0..SHAPES_PER_ENTITY) |s| {
                const offset_x: f32 = @as(f32, @floatFromInt(s)) * 10.0;
                shape_entities[shape_idx] = .{
                    .parent = entity,
                    .collider = Collider{
                        .shape = .{ .box = .{ .width = 20, .height = 20 } },
                        .offset = .{ offset_x, 0 },
                    },
                };
                try child_list.append(allocator, shape_idx);
                shape_idx += 1;
            }

            try children_map.put(entity, child_list);
        }

        // Clear for next iteration
        var iter = children_map.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        children_map.clearRetainingCapacity();
    }
    const create_ns = timer.read();

    // Recreate for subsequent tests
    {
        var shape_idx: usize = 0;
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);

            var child_list = ChildList{};

            for (0..SHAPES_PER_ENTITY) |s| {
                const offset_x: f32 = @as(f32, @floatFromInt(s)) * 10.0;
                shape_entities[shape_idx] = .{
                    .parent = entity,
                    .collider = Collider{
                        .shape = .{ .box = .{ .width = 20, .height = 20 } },
                        .offset = .{ offset_x, 0 },
                    },
                };
                try child_list.append(allocator, shape_idx);
                shape_idx += 1;
            }

            try children_map.put(entity, child_list);
        }
    }

    // Benchmark update (modifying shape properties through hierarchy)
    timer.reset();
    for (0..ITERATIONS) |iter_idx| {
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);
            if (children_map.get(entity)) |child_indices| {
                for (child_indices.items) |idx| {
                    shape_entities[idx].collider.offset[0] += @as(f32, @floatFromInt(iter_idx % 2)) * 0.1;
                }
            }
        }
    }
    const update_ns = timer.read();

    // Benchmark query (find all shapes for specific entities)
    timer.reset();
    var total_shapes: usize = 0;
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |entity_idx| {
            const entity: u64 = @intCast(entity_idx);
            if (children_map.get(entity)) |child_indices| {
                total_shapes += child_indices.items.len;
            }
        }
    }
    const query_ns = timer.read();
    std.mem.doNotOptimizeAway(&total_shapes);

    // Calculate memory
    var mem: usize = TOTAL_SHAPE_ENTITIES * @sizeOf(ShapeEntity);
    mem += @sizeOf(@TypeOf(children_map));
    var mem_iter = children_map.valueIterator();
    while (mem_iter.next()) |list| {
        mem += @sizeOf(ChildList) + list.capacity * @sizeOf(usize);
    }

    const results = BenchResults{
        .create_ns = create_ns,
        .update_ns = update_ns,
        .query_ns = query_ns,
        .memory_bytes = mem,
    };

    printResults("Option C", results);
    return results;
}

fn printResults(name: []const u8, r: BenchResults) void {
    std.debug.print("  {s}:\n", .{name});
    std.debug.print("    Create:           {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.create_ns)) / 1_000_000,
    });
    std.debug.print("    Update:           {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.update_ns)) / 1_000_000,
    });
    std.debug.print("    Query:            {d:>8.2}ms\n", .{
        @as(f64, @floatFromInt(r.query_ns)) / 1_000_000,
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

    const create_fastest = @min(@min(a.create_ns, b.create_ns), c.create_ns);
    const update_fastest = @min(@min(a.update_ns, b.update_ns), c.update_ns);
    const query_fastest = @min(@min(a.query_ns, b.query_ns), c.query_ns);

    std.debug.print("║ Create Compound:                                             ║\n", .{});
    printCompare("  A (Multi-comp)", a.create_ns, create_fastest);
    printCompare("  B (Array)", b.create_ns, create_fastest);
    printCompare("  C (Children)", c.create_ns, create_fastest);

    std.debug.print("║ Update Shapes:                                               ║\n", .{});
    printCompare("  A (Multi-comp)", a.update_ns, update_fastest);
    printCompare("  B (Array)", b.update_ns, update_fastest);
    printCompare("  C (Children)", c.update_ns, update_fastest);

    std.debug.print("║ Query Shapes:                                                ║\n", .{});
    printCompare("  A (Multi-comp)", a.query_ns, query_fastest);
    printCompare("  B (Array)", b.query_ns, query_fastest);
    printCompare("  C (Children)", c.query_ns, query_fastest);

    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Memory comparison
    std.debug.print("║ Memory Usage:                                                ║\n", .{});
    std.debug.print("║   A (Multi-comp):   {d:>8.1} KB                              ║\n", .{@as(f64, @floatFromInt(a.memory_bytes)) / 1024});
    std.debug.print("║   B (Array):        {d:>8.1} KB                              ║\n", .{@as(f64, @floatFromInt(b.memory_bytes)) / 1024});
    std.debug.print("║   C (Children):     {d:>8.1} KB                              ║\n", .{@as(f64, @floatFromInt(c.memory_bytes)) / 1024});

    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Determine winner
    var a_wins: u32 = 0;
    var b_wins: u32 = 0;
    var c_wins: u32 = 0;

    if (a.create_ns == create_fastest) a_wins += 1;
    if (b.create_ns == create_fastest) b_wins += 1;
    if (c.create_ns == create_fastest) c_wins += 1;

    if (a.update_ns == update_fastest) a_wins += 1;
    if (b.update_ns == update_fastest) b_wins += 1;
    if (c.update_ns == update_fastest) c_wins += 1;

    if (a.query_ns == query_fastest) a_wins += 1;
    if (b.query_ns == query_fastest) b_wins += 1;
    if (c.query_ns == query_fastest) c_wins += 1;

    const winner = if (a_wins >= b_wins and a_wins >= c_wins)
        "Option A (Multiple Components)"
    else if (b_wins >= c_wins)
        "Option B (Shapes Array)"
    else
        "Option C (Child Entities)";

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
