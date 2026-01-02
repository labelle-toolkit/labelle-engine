//! Velocity Control Pattern Benchmark
//!
//! Compares different approaches for controlling physics body velocity:
//! - Option A: Direct world methods (setVelocity, getVelocity)
//! - Option B: Velocity component that syncs each frame
//! - Option C: Velocity embedded in RigidBody component
//!
//! Run with: zig build bench-velocity (in physics directory)

const std = @import("std");
const physics = @import("labelle-physics");
const PhysicsWorld = physics.PhysicsWorld;
const RigidBody = physics.RigidBody;
const Collider = physics.Collider;

const Timer = std.time.Timer;

const ENTITY_COUNT: usize = 10_000;
const ITERATIONS: usize = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         Velocity Control Pattern Benchmark                   ║\n", .{});
    std.debug.print("║         {} entities, {} iterations                       ║\n", .{ ENTITY_COUNT, ITERATIONS });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Setup physics world with bodies
    var world = try PhysicsWorld.init(allocator, .{ 0, 0 });
    defer world.deinit();

    std.debug.print("Setting up {} physics bodies...\n", .{ENTITY_COUNT});
    for (0..ENTITY_COUNT) |i| {
        const entity: u64 = @intCast(i);
        try world.createBody(entity, RigidBody{}, .{
            .x = @as(f32, @floatFromInt(i % 100)) * 10,
            .y = @as(f32, @floatFromInt(i / 100)) * 10,
        });
    }
    std.debug.print("Setup complete.\n\n", .{});

    // Run benchmarks
    const results_a = try benchOptionA(&world);
    const results_b = try benchOptionB(allocator);
    const results_c = try benchOptionC(allocator);

    // Print summary
    printSummary(results_a, results_b, results_c);
}

const BenchResults = struct {
    set_velocity_ns: u64,
    get_velocity_ns: u64,
    mixed_rw_ns: u64,
    memory_bytes: usize,
};

/// Option A: Direct world methods
fn benchOptionA(world: *PhysicsWorld) !BenchResults {
    std.debug.print("━━━ Option A: Direct World Methods ━━━\n", .{});

    var timer = try Timer.start();

    // Benchmark set velocity
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |i| {
            world.setLinearVelocity(@intCast(i), .{ 100, -50 });
        }
    }
    const set_ns = timer.read();

    // Benchmark get velocity
    timer.reset();
    var sum: f32 = 0;
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |i| {
            if (world.getLinearVelocity(@intCast(i))) |vel| {
                sum += vel[0];
            }
        }
    }
    const get_ns = timer.read();
    std.mem.doNotOptimizeAway(&sum);

    // Benchmark mixed read/write (realistic pattern)
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |i| {
            const entity: u64 = @intCast(i);
            if (world.getLinearVelocity(entity)) |vel| {
                // Apply friction-like dampening
                world.setLinearVelocity(entity, .{ vel[0] * 0.99, vel[1] * 0.99 });
            }
        }
    }
    const mixed_ns = timer.read();

    const results = BenchResults{
        .set_velocity_ns = set_ns,
        .get_velocity_ns = get_ns,
        .mixed_rw_ns = mixed_ns,
        .memory_bytes = 0, // No additional memory
    };

    printResults("Option A", results);
    return results;
}

/// Option B: Velocity component (simulated)
/// Simulates a Velocity component that would sync to Box2D each frame
fn benchOptionB(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option B: Velocity Component (synced) ━━━\n", .{});

    // Simulate velocity component storage
    const Velocity = struct {
        linear: [2]f32 = .{ 0, 0 },
        angular: f32 = 0,
    };

    var velocities = try allocator.alloc(Velocity, ENTITY_COUNT);
    defer allocator.free(velocities);

    // Initialize
    for (velocities) |*v| {
        v.* = Velocity{};
    }

    // Also need a physics world for the sync cost
    var world = try PhysicsWorld.init(allocator, .{ 0, 0 });
    defer world.deinit();

    for (0..ENTITY_COUNT) |i| {
        try world.createBody(@intCast(i), RigidBody{}, .{
            .x = @as(f32, @floatFromInt(i % 100)) * 10,
            .y = @as(f32, @floatFromInt(i / 100)) * 10,
        });
    }

    var timer = try Timer.start();

    // Benchmark set velocity (component write + sync)
    timer.reset();
    for (0..ITERATIONS) |_| {
        // Write to component
        for (velocities) |*v| {
            v.linear = .{ 100, -50 };
        }
        // Sync to Box2D (would happen once per frame)
        for (0..ENTITY_COUNT) |i| {
            world.setLinearVelocity(@intCast(i), velocities[i].linear);
        }
    }
    const set_ns = timer.read();

    // Benchmark get velocity (sync from Box2D + component read)
    timer.reset();
    var sum: f32 = 0;
    for (0..ITERATIONS) |_| {
        // Sync from Box2D
        for (0..ENTITY_COUNT) |i| {
            if (world.getLinearVelocity(@intCast(i))) |vel| {
                velocities[i].linear = vel;
            }
        }
        // Read from component
        for (velocities) |v| {
            sum += v.linear[0];
        }
    }
    const get_ns = timer.read();
    std.mem.doNotOptimizeAway(&sum);

    // Benchmark mixed (component access + sync)
    timer.reset();
    for (0..ITERATIONS) |_| {
        // Read/modify component
        for (velocities) |*v| {
            v.linear = .{ v.linear[0] * 0.99, v.linear[1] * 0.99 };
        }
        // Sync to Box2D
        for (0..ENTITY_COUNT) |i| {
            world.setLinearVelocity(@intCast(i), velocities[i].linear);
        }
    }
    const mixed_ns = timer.read();

    const results = BenchResults{
        .set_velocity_ns = set_ns,
        .get_velocity_ns = get_ns,
        .mixed_rw_ns = mixed_ns,
        .memory_bytes = ENTITY_COUNT * @sizeOf(Velocity),
    };

    printResults("Option B", results);
    return results;
}

/// Option C: Velocity embedded in RigidBody
/// Simulates velocity fields directly on RigidBody component
fn benchOptionC(allocator: std.mem.Allocator) !BenchResults {
    std.debug.print("━━━ Option C: Velocity in RigidBody ━━━\n", .{});

    // Extended RigidBody with velocity
    const RigidBodyWithVelocity = struct {
        body_type: physics.BodyType = .dynamic,
        mass: f32 = 1.0,
        gravity_scale: f32 = 1.0,
        linear_damping: f32 = 0.0,
        angular_damping: f32 = 0.0,
        fixed_rotation: bool = false,
        bullet: bool = false,
        awake: bool = true,
        allow_sleep: bool = true,
        // Added velocity fields
        linear_velocity: [2]f32 = .{ 0, 0 },
        angular_velocity: f32 = 0,
    };

    var bodies = try allocator.alloc(RigidBodyWithVelocity, ENTITY_COUNT);
    defer allocator.free(bodies);

    for (bodies) |*b| {
        b.* = RigidBodyWithVelocity{};
    }

    // Physics world for sync
    var world = try PhysicsWorld.init(allocator, .{ 0, 0 });
    defer world.deinit();

    for (0..ENTITY_COUNT) |i| {
        try world.createBody(@intCast(i), RigidBody{}, .{
            .x = @as(f32, @floatFromInt(i % 100)) * 10,
            .y = @as(f32, @floatFromInt(i / 100)) * 10,
        });
    }

    var timer = try Timer.start();

    // Benchmark set velocity
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (bodies) |*b| {
            b.linear_velocity = .{ 100, -50 };
        }
        // Sync
        for (0..ENTITY_COUNT) |i| {
            world.setLinearVelocity(@intCast(i), bodies[i].linear_velocity);
        }
    }
    const set_ns = timer.read();

    // Benchmark get velocity
    timer.reset();
    var sum: f32 = 0;
    for (0..ITERATIONS) |_| {
        for (0..ENTITY_COUNT) |i| {
            if (world.getLinearVelocity(@intCast(i))) |vel| {
                bodies[i].linear_velocity = vel;
            }
        }
        for (bodies) |b| {
            sum += b.linear_velocity[0];
        }
    }
    const get_ns = timer.read();
    std.mem.doNotOptimizeAway(&sum);

    // Benchmark mixed
    timer.reset();
    for (0..ITERATIONS) |_| {
        for (bodies) |*b| {
            b.linear_velocity = .{ b.linear_velocity[0] * 0.99, b.linear_velocity[1] * 0.99 };
        }
        for (0..ENTITY_COUNT) |i| {
            world.setLinearVelocity(@intCast(i), bodies[i].linear_velocity);
        }
    }
    const mixed_ns = timer.read();

    const results = BenchResults{
        .set_velocity_ns = set_ns,
        .get_velocity_ns = get_ns,
        .mixed_rw_ns = mixed_ns,
        .memory_bytes = ENTITY_COUNT * (@sizeOf(RigidBodyWithVelocity) - @sizeOf(RigidBody)),
    };

    printResults("Option C", results);
    return results;
}

fn printResults(name: []const u8, r: BenchResults) void {
    const total_ops = ENTITY_COUNT * ITERATIONS;
    const set_per_ms = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(r.set_velocity_ns)) / 1_000_000);
    const get_per_ms = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(r.get_velocity_ns)) / 1_000_000);
    const mixed_per_ms = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(r.mixed_rw_ns)) / 1_000_000);

    std.debug.print("  {s}:\n", .{name});
    std.debug.print("    Set velocity:   {d:>8.2}ms ({d:>10.0} ops/ms)\n", .{
        @as(f64, @floatFromInt(r.set_velocity_ns)) / 1_000_000,
        set_per_ms,
    });
    std.debug.print("    Get velocity:   {d:>8.2}ms ({d:>10.0} ops/ms)\n", .{
        @as(f64, @floatFromInt(r.get_velocity_ns)) / 1_000_000,
        get_per_ms,
    });
    std.debug.print("    Mixed R/W:      {d:>8.2}ms ({d:>10.0} ops/ms)\n", .{
        @as(f64, @floatFromInt(r.mixed_rw_ns)) / 1_000_000,
        mixed_per_ms,
    });
    if (r.memory_bytes > 0) {
        std.debug.print("    Memory overhead: {} bytes ({d:.1} KB)\n", .{
            r.memory_bytes,
            @as(f64, @floatFromInt(r.memory_bytes)) / 1024,
        });
    } else {
        std.debug.print("    Memory overhead: 0 bytes\n", .{});
    }
    std.debug.print("\n", .{});
}

fn printSummary(a: BenchResults, b: BenchResults, c: BenchResults) void {
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                         SUMMARY                              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Find fastest for each category
    const set_fastest = @min(@min(a.set_velocity_ns, b.set_velocity_ns), c.set_velocity_ns);
    const get_fastest = @min(@min(a.get_velocity_ns, b.get_velocity_ns), c.get_velocity_ns);
    const mixed_fastest = @min(@min(a.mixed_rw_ns, b.mixed_rw_ns), c.mixed_rw_ns);

    std.debug.print("║ Set Velocity:                                                ║\n", .{});
    printCompare("  A (Direct)", a.set_velocity_ns, set_fastest);
    printCompare("  B (Component)", b.set_velocity_ns, set_fastest);
    printCompare("  C (In RigidBody)", c.set_velocity_ns, set_fastest);

    std.debug.print("║ Get Velocity:                                                ║\n", .{});
    printCompare("  A (Direct)", a.get_velocity_ns, get_fastest);
    printCompare("  B (Component)", b.get_velocity_ns, get_fastest);
    printCompare("  C (In RigidBody)", c.get_velocity_ns, get_fastest);

    std.debug.print("║ Mixed Read/Write:                                            ║\n", .{});
    printCompare("  A (Direct)", a.mixed_rw_ns, mixed_fastest);
    printCompare("  B (Component)", b.mixed_rw_ns, mixed_fastest);
    printCompare("  C (In RigidBody)", c.mixed_rw_ns, mixed_fastest);

    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});

    // Determine winner
    var a_wins: u32 = 0;
    var b_wins: u32 = 0;
    var c_wins: u32 = 0;

    if (a.set_velocity_ns == set_fastest) a_wins += 1;
    if (b.set_velocity_ns == set_fastest) b_wins += 1;
    if (c.set_velocity_ns == set_fastest) c_wins += 1;

    if (a.get_velocity_ns == get_fastest) a_wins += 1;
    if (b.get_velocity_ns == get_fastest) b_wins += 1;
    if (c.get_velocity_ns == get_fastest) c_wins += 1;

    if (a.mixed_rw_ns == mixed_fastest) a_wins += 1;
    if (b.mixed_rw_ns == mixed_fastest) b_wins += 1;
    if (c.mixed_rw_ns == mixed_fastest) c_wins += 1;

    const winner = if (a_wins >= b_wins and a_wins >= c_wins)
        "Option A (Direct World Methods)"
    else if (b_wins >= c_wins)
        "Option B (Velocity Component)"
    else
        "Option C (Velocity in RigidBody)";

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
