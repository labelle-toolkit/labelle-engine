// ECS Benchmark - compares performance between ECS backends
//
// This benchmark uses a SINGLE registry/world throughout to avoid
// zflecs stability issues with rapid world creation/destruction.
//
// Benchmarks:
// - Entity creation/destruction (within single world)
// - Component add/remove
// - Component lookup (tryGet)
// - View/Query iteration
//
// Run with: zig build bench -Decs_backend=zig_ecs
//           zig build bench -Decs_backend=zflecs

const std = @import("std");
const ecs = @import("ecs");
const build_options = @import("build_options");

const Entity = ecs.Entity;
const Registry = ecs.Registry;

// Test components
const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

const Health = struct {
    current: u32 = 100,
    max: u32 = 100,
};

const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
};

const Sprite = struct {
    texture_id: u32 = 0,
    width: u32 = 32,
    height: u32 = 32,
    layer: i32 = 0,
};

// Benchmark configuration
const WARMUP_ITERATIONS = 50;
const BENCH_ITERATIONS = 500;
const ENTITY_COUNTS = [_]usize{ 100, 1000, 10000 };

const BenchResult = struct {
    name: []const u8,
    entity_count: usize,
    min_ns: u64,
    max_ns: u64,
    avg_ns: u64,
    ops_per_sec: u64,
};

fn formatTime(ns: u64) struct { value: f64, unit: []const u8 } {
    if (ns >= 1_000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0, .unit = "s" };
    } else if (ns >= 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000_000.0, .unit = "ms" };
    } else if (ns >= 1_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1_000.0, .unit = "μs" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(ns)), .unit = "ns" };
    }
}

fn printResult(result: BenchResult) void {
    const avg_time = formatTime(result.avg_ns);
    const min_time = formatTime(result.min_ns);
    const max_time = formatTime(result.max_ns);

    std.debug.print("  {s:<35} | {d:>6} entities | avg: {d:>8.2}{s:<2} | min: {d:>8.2}{s:<2} | max: {d:>8.2}{s:<2} | {d:>12} ops/s\n", .{
        result.name,
        result.entity_count,
        avg_time.value,
        avg_time.unit,
        min_time.value,
        min_time.unit,
        max_time.value,
        max_time.unit,
        result.ops_per_sec,
    });
}

// Benchmark: Entity creation only
fn benchEntityCreation(registry: *Registry, count: usize, entities: []Entity) void {
    for (0..count) |i| {
        entities[i] = registry.create();
    }
}

// Benchmark: Entity destruction only
fn benchEntityDestruction(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        registry.destroy(entity);
    }
}

// Benchmark: Add single component
fn benchAddComponent(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        registry.add(entity, Position{ .x = 1.0, .y = 2.0 });
    }
}

// Benchmark: Add multiple components (3)
fn benchAddMultipleComponents(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        registry.add(entity, Position{ .x = 1.0, .y = 2.0 });
        registry.add(entity, Velocity{ .dx = 0.5, .dy = -0.5 });
        registry.add(entity, Health{ .current = 100, .max = 100 });
    }
}

// Benchmark: Add complex components (5)
fn benchAddComplexComponents(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        registry.add(entity, Position{ .x = 1.0, .y = 2.0 });
        registry.add(entity, Velocity{ .dx = 0.5, .dy = -0.5 });
        registry.add(entity, Health{ .current = 100, .max = 100 });
        registry.add(entity, Transform{ .x = 0, .y = 0, .rotation = 0, .scale_x = 1, .scale_y = 1 });
        registry.add(entity, Sprite{ .texture_id = 1, .width = 32, .height = 32, .layer = 0 });
    }
}

// Benchmark: Component lookup (single)
fn benchComponentLookup(registry: *Registry, entities: []const Entity) void {
    var sum: f32 = 0;
    for (entities) |entity| {
        if (registry.tryGet(Position, entity)) |pos| {
            sum += pos.x + pos.y;
        }
    }
    std.mem.doNotOptimizeAway(sum);
}

// Benchmark: Multiple component lookup
fn benchMultipleComponentLookup(registry: *Registry, entities: []const Entity) void {
    var sum: f32 = 0;
    for (entities) |entity| {
        if (registry.tryGet(Position, entity)) |pos| {
            if (registry.tryGet(Velocity, entity)) |vel| {
                sum += pos.x + pos.y + vel.dx + vel.dy;
            }
        }
    }
    std.mem.doNotOptimizeAway(sum);
}

// Benchmark: Component removal
fn benchRemoveComponent(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        registry.remove(Position, entity);
    }
}

// Benchmark: Game loop iteration (per-entity lookup pattern)
fn benchGameLoopIteration(registry: *Registry, entities: []const Entity) void {
    for (entities) |entity| {
        if (registry.tryGet(Position, entity)) |pos| {
            if (registry.tryGet(Velocity, entity)) |vel| {
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        }
    }
}

// Benchmark: View-based iteration (backend-specific)
fn benchViewIteration(registry: *Registry) void {
    switch (build_options.ecs_backend) {
        .zig_ecs => {
            // zig_ecs uses sparse set views with multi-component iteration
            var view = registry.view(.{ Position, Velocity });
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                const pos = view.get(Position, entity);
                const vel = view.getConst(Velocity, entity);
                pos.x += vel.dx;
                pos.y += vel.dy;
            }
        },
        .zflecs => {
            // zflecs uses archetype-based iteration
            const flecs = @import("zflecs");
            var it = registry.each(Position);
            while (flecs.each_next(&it)) {
                if (flecs.field(&it, Position, 0)) |positions| {
                    for (positions) |*pos| {
                        pos.x += 1.0;
                        pos.y += 1.0;
                    }
                }
            }
        },
        .mr_ecs => {
            // mr_ecs uses archetype-based iteration via Entities.iterator()
            // Note: Requires Zig 0.16+ - this branch should not be compiled on 0.15
            @compileError("mr_ecs benchmark requires Zig 0.16.0+");
        },
    }
}

// Benchmark: Raw slice iteration (zig_ecs specific - fastest possible)
fn benchRawIteration(registry: *Registry) void {
    if (build_options.ecs_backend != .zig_ecs) return;
    var view = registry.basicView(Position);
    const positions = view.raw();
    for (positions) |*pos| {
        pos.x += 1.0;
        pos.y += 1.0;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_name = switch (build_options.ecs_backend) {
        .zig_ecs => "zig_ecs",
        .zflecs => "zflecs",
        .mr_ecs => "mr_ecs",
    };

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                                    ECS Benchmark - Backend: {s:<10}                                          ║\n", .{backend_name});
    std.debug.print("║                                    (Single World - No Recreation)                                                ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Warmup: {d} iterations | Benchmark: {d} iterations                                                              ║\n", .{ WARMUP_ITERATIONS, BENCH_ITERATIONS });
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create a SINGLE registry for ALL benchmarks
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Pre-allocate entity buffer for the largest test
    const max_entities = ENTITY_COUNTS[ENTITY_COUNTS.len - 1];
    var entity_buffer = try allocator.alloc(Entity, max_entities);
    defer allocator.free(entity_buffer);

    for (ENTITY_COUNTS) |entity_count| {
        std.debug.print("─── Entity Count: {d} ───\n", .{entity_count});

        const entities = entity_buffer[0..entity_count];

        // Create entities once for this entity count - they'll be reused across benchmarks
        // NOTE: For zflecs, entity IDs cannot be reused after destruction due to generation counters
        // being stored in the upper 32 bits which we truncate. So we keep entities alive.
        benchEntityCreation(&registry, entity_count, entities);

        // 1. Entity Creation Benchmark - zig_ecs only (zflecs has entity ID generation issues with 32-bit truncation)
        if (build_options.ecs_backend == .zig_ecs) {
            const temp_entities = try allocator.alloc(Entity, entity_count);
            defer allocator.free(temp_entities);

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchEntityCreation(&registry, entity_count, temp_entities);
                const end = std.time.nanoTimestamp();

                // Destroy temp entities (not reused)
                benchEntityDestruction(&registry, temp_entities);

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Entity Creation",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 2. Entity Lifecycle - zig_ecs only
        if (build_options.ecs_backend == .zig_ecs) {
            const temp_entities = try allocator.alloc(Entity, entity_count);
            defer allocator.free(temp_entities);

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchEntityCreation(&registry, entity_count, temp_entities);
                benchEntityDestruction(&registry, temp_entities);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Entity Lifecycle (create+destroy)",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count * 2)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 3. Add Single Component - uses persistent entities, measures add/remove cycle
        {
            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchAddComponent(&registry, entities);
                const end = std.time.nanoTimestamp();

                // Remove for next iteration
                benchRemoveComponent(&registry, entities);

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Add Single Component",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 4. Component Lookup (single) - uses persistent entities
        {
            // Add components for lookup
            benchAddComponent(&registry, entities);

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchComponentLookup(&registry, entities);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            // Clean up components (keep entities)
            benchRemoveComponent(&registry, entities);

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Component Lookup (single)",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 5. Multiple Component Lookup - uses persistent entities
        {
            // Add components
            for (entities) |entity| {
                registry.add(entity, Position{ .x = 1.0, .y = 2.0 });
                registry.add(entity, Velocity{ .dx = 0.5, .dy = -0.5 });
            }

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchMultipleComponentLookup(&registry, entities);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            // Clean up components (keep entities)
            for (entities) |entity| {
                registry.remove(Position, entity);
                registry.remove(Velocity, entity);
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Component Lookup (2 components)",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count * 2)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 6. Game Loop Iteration (per-entity lookup pattern) - uses persistent entities
        {
            // Add components
            for (entities) |entity| {
                registry.add(entity, Position{ .x = 0, .y = 0 });
                registry.add(entity, Velocity{ .dx = 1.0, .dy = 1.0 });
            }

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchGameLoopIteration(&registry, entities);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            // Clean up components (keep entities)
            for (entities) |entity| {
                registry.remove(Position, entity);
                registry.remove(Velocity, entity);
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Game Loop Iteration",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 7. View/Query Iteration - uses persistent entities
        {
            // Add components
            for (entities) |entity| {
                registry.add(entity, Position{ .x = 0, .y = 0 });
                registry.add(entity, Velocity{ .dx = 1.0, .dy = 1.0 });
            }

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchViewIteration(&registry);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            // Clean up components (keep entities)
            for (entities) |entity| {
                registry.remove(Position, entity);
                registry.remove(Velocity, entity);
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "View/Query Iteration",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 8. Raw Slice Iteration (zig_ecs only) - uses persistent entities
        if (build_options.ecs_backend == .zig_ecs) {
            // Add components
            for (entities) |entity| {
                registry.add(entity, Position{ .x = 0, .y = 0 });
            }

            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                const start = std.time.nanoTimestamp();
                benchRawIteration(&registry);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            // Clean up components (keep entities)
            for (entities) |entity| {
                registry.remove(Position, entity);
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Raw Slice Iteration",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // 9. Component Removal - uses persistent entities
        {
            var min: u64 = std.math.maxInt(u64);
            var max: u64 = 0;
            var total: u64 = 0;

            for (0..BENCH_ITERATIONS) |_| {
                // Add components first
                benchAddComponent(&registry, entities);

                const start = std.time.nanoTimestamp();
                benchRemoveComponent(&registry, entities);
                const end = std.time.nanoTimestamp();

                const elapsed: u64 = @intCast(end - start);
                min = @min(min, elapsed);
                max = @max(max, elapsed);
                total += elapsed;
            }

            const avg = total / BENCH_ITERATIONS;
            printResult(.{
                .name = "Component Removal",
                .entity_count = entity_count,
                .min_ns = min,
                .max_ns = max,
                .avg_ns = avg,
                .ops_per_sec = if (avg > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(entity_count)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0))) else 0,
            });
        }

        // For zig_ecs: Destroy the persistent entities at the end of this entity count batch
        // For zflecs: Keep entities alive to avoid generation counter issues with 32-bit ID truncation
        if (build_options.ecs_backend == .zig_ecs) {
            benchEntityDestruction(&registry, entities);
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("Benchmark complete.\n", .{});
}
