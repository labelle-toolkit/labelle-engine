//! Physics Benchmarks
//!
//! Performance benchmarks for the physics module.
//! Run with: zig build bench (in physics directory)

const std = @import("std");
const PhysicsWorld = @import("world.zig").PhysicsWorld;
const components = @import("components.zig");
const RigidBody = components.RigidBody;
const Collider = components.Collider;

const Timer = std.time.Timer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Physics Module Benchmarks ===\n\n", .{});

    try benchBodyLifecycle(allocator);
    try benchSimulationStep(allocator, 100);
    try benchSimulationStep(allocator, 1000);
    try benchSimulationStep(allocator, 5000);
    try benchCollisionDetection(allocator);
    try benchCollisionQuery(allocator);
    try benchEcsSync(allocator);

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
}

/// Benchmark body creation and destruction
fn benchBodyLifecycle(allocator: std.mem.Allocator) !void {
    std.debug.print("Body Lifecycle (create/destroy 10000 bodies):\n", .{});

    var world = try PhysicsWorld.init(allocator, .{ 0, 9.8 * 100 });
    defer world.deinit();

    const iterations = 10000;
    var timer = try Timer.start();

    // Create bodies
    for (0..iterations) |i| {
        const entity: u64 = @intCast(i);
        try world.createBody(entity, RigidBody{}, .{
            .x = @floatFromInt(i % 100 * 10),
            .y = @floatFromInt(i / 100 * 10),
        });
    }

    const create_ns = timer.read();
    timer.reset();

    // Destroy bodies
    for (0..iterations) |i| {
        world.destroyBody(@intCast(i));
    }

    const destroy_ns = timer.read();

    std.debug.print("  Create: {d:.2}ms ({d:.0} bodies/ms)\n", .{
        @as(f64, @floatFromInt(create_ns)) / 1_000_000,
        @as(f64, iterations) / (@as(f64, @floatFromInt(create_ns)) / 1_000_000),
    });
    std.debug.print("  Destroy: {d:.2}ms ({d:.0} bodies/ms)\n\n", .{
        @as(f64, @floatFromInt(destroy_ns)) / 1_000_000,
        @as(f64, iterations) / (@as(f64, @floatFromInt(destroy_ns)) / 1_000_000),
    });
}

/// Benchmark physics step with varying body counts
fn benchSimulationStep(allocator: std.mem.Allocator, body_count: usize) !void {
    std.debug.print("Simulation Step ({} dynamic bodies):\n", .{body_count});

    var world = try PhysicsWorld.init(allocator, .{ 0, 9.8 * 100 });
    defer world.deinit();

    // Create ground (static)
    try world.createBody(0, RigidBody{ .body_type = .static }, .{ .x = 0, .y = 500 });
    try world.addCollider(0, Collider{
        .shape = .{ .box = .{ .width = 1000, .height = 20 } },
    });

    // Create dynamic bodies in a grid
    for (1..body_count + 1) |i| {
        const entity: u64 = @intCast(i);
        const row = i / 50;
        const col = i % 50;
        try world.createBody(entity, RigidBody{}, .{
            .x = @as(f32, @floatFromInt(col)) * 15 + 50,
            .y = @as(f32, @floatFromInt(row)) * 15 + 50,
        });
        try world.addCollider(entity, Collider{
            .shape = .{ .circle = .{ .radius = 5 } },
        });
    }

    // Warm up
    for (0..10) |_| {
        world.update(1.0 / 60.0);
    }

    // Benchmark
    const iterations = 100;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        world.update(1.0 / 60.0);
    }

    const total_ns = timer.read();
    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000;

    std.debug.print("  Average step: {d:.3}ms ({d:.1} FPS equivalent)\n", .{
        avg_ms,
        1000.0 / avg_ms,
    });
    std.debug.print("  Total ({} steps): {d:.2}ms\n\n", .{
        iterations,
        @as(f64, @floatFromInt(total_ns)) / 1_000_000,
    });
}

/// Benchmark collision detection with many overlapping bodies
fn benchCollisionDetection(allocator: std.mem.Allocator) !void {
    std.debug.print("Collision Detection (500 overlapping circles):\n", .{});

    var world = try PhysicsWorld.init(allocator, .{ 0, 0 }); // No gravity
    defer world.deinit();

    // Create overlapping circles in a small area
    const body_count: usize = 500;
    for (0..body_count) |i| {
        const entity: u64 = @intCast(i);
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi * 2.0 / @as(f32, @floatFromInt(body_count)));
        const radius: f32 = 50 + @as(f32, @floatFromInt(i % 10)) * 5;
        try world.createBody(entity, RigidBody{}, .{
            .x = 250 + @cos(angle) * radius,
            .y = 250 + @sin(angle) * radius,
        });
        try world.addCollider(entity, Collider{
            .shape = .{ .circle = .{ .radius = 20 } },
        });
    }

    // Warm up
    for (0..10) |_| {
        world.update(1.0 / 60.0);
    }

    // Benchmark
    const iterations = 100;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        world.update(1.0 / 60.0);
    }

    const total_ns = timer.read();
    const avg_ns = total_ns / iterations;

    std.debug.print("  Average step: {d:.3}ms\n", .{
        @as(f64, @floatFromInt(avg_ns)) / 1_000_000,
    });

    // Count collisions
    world.update(1.0 / 60.0);
    std.debug.print("  Collision events per frame: {}\n\n", .{
        world.getCollisionBeginEvents().len,
    });
}

/// Benchmark collision event query API
fn benchCollisionQuery(allocator: std.mem.Allocator) !void {
    std.debug.print("Collision Query API:\n", .{});

    var world = try PhysicsWorld.init(allocator, .{ 0, 9.8 * 100 });
    defer world.deinit();

    // Create bodies that will collide
    for (0..100) |i| {
        const entity: u64 = @intCast(i);
        try world.createBody(entity, RigidBody{}, .{
            .x = @as(f32, @floatFromInt(i % 10)) * 30 + 100,
            .y = @as(f32, @floatFromInt(i / 10)) * 30 + 100,
        });
        try world.addCollider(entity, Collider{
            .shape = .{ .box = .{ .width = 28, .height = 28 } },
        });
    }

    // Run simulation to generate collisions
    for (0..60) |_| {
        world.update(1.0 / 60.0);
    }

    // Benchmark query iteration
    const iterations = 10000;
    var timer = try Timer.start();
    var total_events: usize = 0;

    for (0..iterations) |_| {
        world.update(1.0 / 60.0);
        total_events += world.getCollisionBeginEvents().len;
        total_events += world.getCollisionEndEvents().len;
    }

    const total_ns = timer.read();

    std.debug.print("  {} iterations: {d:.2}ms\n", .{
        iterations,
        @as(f64, @floatFromInt(total_ns)) / 1_000_000,
    });
    std.debug.print("  Total events processed: {}\n", .{total_events});
    std.debug.print("  Avg query time: {d:.0}ns\n\n", .{
        @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)),
    });
}

/// Benchmark ECS synchronization overhead
fn benchEcsSync(allocator: std.mem.Allocator) !void {
    std.debug.print("ECS Sync Overhead (position read/write):\n", .{});

    var world = try PhysicsWorld.init(allocator, .{ 0, 9.8 * 100 });
    defer world.deinit();

    const body_count: usize = 1000;
    for (0..body_count) |i| {
        const entity: u64 = @intCast(i);
        try world.createBody(entity, RigidBody{}, .{
            .x = @as(f32, @floatFromInt(i % 50)) * 15,
            .y = @as(f32, @floatFromInt(i / 50)) * 15,
        });
    }

    // Benchmark getPosition calls
    const iterations = 10000;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        for (0..body_count) |i| {
            _ = world.getPosition(@intCast(i));
        }
    }

    const read_ns = timer.read();
    timer.reset();

    // Benchmark setLinearVelocity calls
    for (0..iterations) |_| {
        for (0..body_count) |i| {
            world.setLinearVelocity(@intCast(i), .{ 10, 0 });
        }
    }

    const write_ns = timer.read();

    const reads_per_ms = @as(f64, @floatFromInt(iterations * body_count)) / (@as(f64, @floatFromInt(read_ns)) / 1_000_000);
    const writes_per_ms = @as(f64, @floatFromInt(iterations * body_count)) / (@as(f64, @floatFromInt(write_ns)) / 1_000_000);

    std.debug.print("  Position reads: {d:.0}/ms\n", .{reads_per_ms});
    std.debug.print("  Velocity writes: {d:.0}/ms\n\n", .{writes_per_ms});
}
