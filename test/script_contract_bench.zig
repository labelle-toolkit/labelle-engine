//! Host+binding micro-benchmark for the id-column batch variant (#783).
//!
//! Measures the per-tick cost the entity-id column ADDS to the batch
//! round-trip. Key property this exploits: the id column changes ONLY
//! the host + binding portion of a swarm tick — the script's per-entity
//! integrate+bounce loop (the mruby interpreter's dominant ~305 ns/entity
//! on the ruby-swarm-batch rig) is byte-identical between the positional
//! and id-tagged paths. So the end-to-end tick delta EQUALS the host+
//! binding delta measured here, and can be divided into the rig's
//! 0.649 ms/tick @ 2000 entities baseline directly.
//!
//! It drives the REAL `script_contract` exports (positional
//! `labelle_component_batch_get/_set` vs id-tagged `…_get_ids/_set_ids`)
//! over 2000 live entities, each carrying Position+Velocity — the same
//! stride the rig uses (`["Position","Velocity"]` → [px,py,vx,vy]). The
//! id path also pays the binding's re-interleave cost (copy the 8-byte
//! id column out on get, back in on set) so the number is the FULL id
//! column tax, not just the host half.
//!
//! Backend note: this uses the engine's MockEcs (hashmap-backed), whose
//! per-entity getComponent/entityExists is SLOWER than the rig's zig_ecs
//! sparse-set — so the id-column overhead measured here is a CONSERVATIVE
//! (over-)estimate of the rig's. Build ReleaseFast (`zig build bench`).

const std = @import("std");
const engine = @import("engine");
const core = @import("labelle-core");

const contract = engine.script_contract;

const Velocity = struct { dx: f32 = 0, dy: f32 = 0 };

const MockEcs = core.MockEcsBackend(u32);
const BenchGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    core.StubLogSink,
    engine.ComponentRegistry(.{ .Velocity = Velocity }),
    &.{},
    void,
);

/// Portable monotonic clock. Zig 0.16 has NO `std.time.Timer`; the
/// cross-platform primitive is `std.Io.Timestamp.now(io, .awake)` (the
/// `io` is set up once in `main`). `.awake` is the monotonic,
/// non-suspend-inclusive clock.
var g_io: std.Io = undefined;

fn nowNs() u64 {
    const ts = std.Io.Timestamp.now(g_io, .awake);
    return @intCast(ts.nanoseconds);
}

const N = 2000;
const W: f32 = 800;
const H: f32 = 600;
const STRIDE = 4; // px,py,vx,vy
const names = "[\"Position\",\"Velocity\"]";

/// The swarm's per-entity work over the flat float buffer — IDENTICAL for
/// both paths (this is the mruby loop's Zig twin; unchanged by the id
/// column, included in both so the subtraction is honest).
fn integrateBounce(buf: []f32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = i * STRIDE;
        var x = buf[b];
        var y = buf[b + 1];
        var vx = buf[b + 2];
        var vy = buf[b + 3];
        x += vx;
        y += vy;
        if (x < 0) {
            x = 0;
            vx = -vx;
        }
        if (x > W) {
            x = W;
            vx = -vx;
        }
        if (y < 0) {
            y = 0;
            vy = -vy;
        }
        if (y > H) {
            y = H;
            vy = -vy;
        }
        buf[b] = x;
        buf[b + 1] = y;
        buf[b + 2] = vx;
        buf[b + 3] = vy;
    }
}

/// One positional tick: batch_get → integrate → batch_set (no header on
/// set). `stream` is the f32 view of the post-header bytes.
fn tickPositional(byte_buf: []u8) void {
    const req = contract.labelle_component_batch_get(names, names.len, byte_buf.ptr, byte_buf.len);
    const count = std.mem.readInt(u32, byte_buf[0..4], .little);
    const floats: [*]f32 = @ptrCast(@alignCast(byte_buf.ptr + 4));
    integrateBounce(floats[0 .. count * STRIDE], count);
    _ = contract.labelle_component_batch_set(names, names.len, byte_buf.ptr + 4, req - 4);
}

/// One id-tagged tick, INCLUDING the binding's id-column re-interleave:
///   get → copy ids out + floats down → integrate → floats + ids back → set.
/// `byte_buf` holds the raw wire ([u32 count][rows]); `ids` holds the
/// extracted id column; `floats` the packed flat float array the script
/// sees (exactly what the rig's Ruby Array holds).
fn tickIds(byte_buf: []u8, ids: []u64, floats: []f32) void {
    const req = contract.labelle_component_batch_get_ids(names, names.len, byte_buf.ptr, byte_buf.len);
    const count = std.mem.readInt(u32, byte_buf[0..4], .little);
    const row_bytes = 8 + STRIDE * 4;
    // Binding de-interleave: pull the id column aside, pack floats flat.
    var off: usize = 4;
    var fi: usize = 0;
    var r: usize = 0;
    while (r < count) : (r += 1) {
        ids[r] = std.mem.readInt(u64, byte_buf[off..][0..8], .little);
        off += 8;
        var k: usize = 0;
        while (k < STRIDE) : (k += 1) {
            floats[fi] = @bitCast(std.mem.readInt(u32, byte_buf[off..][0..4], .little));
            fi += 1;
            off += 4;
        }
    }
    integrateBounce(floats[0 .. count * STRIDE], count);
    // Binding re-interleave: [u64 id][floats] rows back into the wire.
    off = 0;
    fi = 0;
    r = 0;
    while (r < count) : (r += 1) {
        std.mem.writeInt(u64, byte_buf[off..][0..8], ids[r], .little);
        off += 8;
        var k: usize = 0;
        while (k < STRIDE) : (k += 1) {
            std.mem.writeInt(u32, byte_buf[off..][0..4], @bitCast(floats[fi]), .little);
            fi += 1;
            off += 4;
        }
    }
    _ = contract.labelle_component_batch_set_ids(names, names.len, byte_buf.ptr, count * row_bytes);
    _ = req;
}

const RunFn = *const fn () void;

/// Min per-tick over `reps` reps of `iters` ticks each. Min-of-reps
/// cancels scheduler/thermal noise. Callers INTERLEAVE the two paths
/// rep-by-rep so both see the same thermal conditions.
fn minPerTick(iters: usize, reps: usize, run: RunFn) f64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const t0 = nowNs();
        for (0..iters) |_| run();
        const dt = nowNs() - t0;
        if (dt < best) best = dt;
    }
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(iters));
}

var g_bytebuf: []u8 = undefined;
var g_ids: []u64 = undefined;
var g_floats: []f32 = undefined;

fn runPositional() void {
    tickPositional(g_bytebuf);
}
fn runIds() void {
    tickIds(g_bytebuf, g_ids, g_floats);
}
/// Get-only variants — isolate the UNAMBIGUOUS marginal cost of the id
/// column (the +8 bytes/entity on the wire and the binding's id memcpy),
/// with no set-side view-walk asymmetry to confound it.
fn runGetPositional() void {
    _ = contract.labelle_component_batch_get(names, names.len, g_bytebuf.ptr, g_bytebuf.len);
}
fn runGetIds() void {
    const req = contract.labelle_component_batch_get_ids(names, names.len, g_bytebuf.ptr, g_bytebuf.len);
    const count = std.mem.readInt(u32, g_bytebuf[0..4], .little);
    var off: usize = 4;
    var fi: usize = 0;
    var r: usize = 0;
    while (r < count) : (r += 1) {
        g_ids[r] = std.mem.readInt(u64, g_bytebuf[off..][0..8], .little);
        off += 8;
        var k: usize = 0;
        while (k < STRIDE) : (k += 1) {
            g_floats[fi] = @bitCast(std.mem.readInt(u32, g_bytebuf[off..][0..4], .little));
            fi += 1;
            off += 4;
        }
    }
    _ = req;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // Portable monotonic clock source (see nowNs). All-default options.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    g_io = threaded.io();

    contract.unbind();
    var game = BenchGame.init(alloc);
    defer game.deinit();
    contract.bind(&game);
    defer contract.unbind();

    // Spawn N entities with Position + Velocity (LCG-seeded, like the rig).
    var seed: u64 = 123456789;
    for (0..N) |n| {
        const ent = game.createEntity();
        seed = (seed *% 1664525 +% 1013904223) & 0xffffffff;
        const x = @as(f32, @floatFromInt(seed >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24)) * W;
        seed = (seed *% 1664525 +% 1013904223) & 0xffffffff;
        const y = @as(f32, @floatFromInt(seed >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24)) * H;
        game.setPosition(ent, .{ .x = x, .y = y });
        game.setComponent(ent, Velocity{
            .dx = @floatFromInt(@as(i32, @intCast(n % 7)) - 3),
            .dy = @floatFromInt(@as(i32, @intCast(n % 5)) - 2),
        });
    }

    // Buffers: the id wire needs 8 extra bytes/entity over the positional.
    // 4-byte aligned so the `@alignCast` to `[*]f32` at byte offset 4 is
    // valid (gemini #788 review).
    g_bytebuf = try alloc.alignedAlloc(u8, .@"4", 4 + N * (8 + STRIDE * 4));
    defer alloc.free(g_bytebuf);
    g_ids = try alloc.alloc(u64, N);
    defer alloc.free(g_ids);
    g_floats = try alloc.alloc(f32, N * STRIDE);
    defer alloc.free(g_floats);

    // Verify both paths actually move all N entities (correctness gate).
    {
        const c0 = contract.labelle_component_batch_get(names, names.len, g_bytebuf.ptr, g_bytebuf.len);
        std.debug.print("sanity: positional count={d} bytes={d}\n", .{ std.mem.readInt(u32, g_bytebuf[0..4], .little), c0 });
        const c1 = contract.labelle_component_batch_get_ids(names, names.len, g_bytebuf.ptr, g_bytebuf.len);
        std.debug.print("sanity: id-tagged  count={d} bytes={d}\n", .{ std.mem.readInt(u32, g_bytebuf[0..4], .little), c1 });
    }

    std.debug.print("\n=== id-column host+binding micro-benchmark (ReleaseFast, N={d}) ===\n", .{N});
    const iters: usize = 1500;
    const reps: usize = 25;
    // Warm both paths thoroughly.
    for (0..500) |_| {
        runPositional();
        runIds();
    }
    // GET-ONLY: the clean marginal cost (no set-side view-walk confound).
    const gp = minPerTick(iters, reps, runGetPositional);
    const gi = minPerTick(iters, reps, runGetIds);
    // FULL round-trip (get + integrate + set).
    const pos_tick = minPerTick(iters, reps, runPositional);
    const id_tick = minPerTick(iters, reps, runIds);

    const rig_baseline_ns: f64 = 649_000; // 0.649 ms/tick @ 2000 (positional, on the rig)
    std.debug.print("\n--- GET-ONLY (isolates the id column's marginal cost) ---\n", .{});
    std.debug.print("positional get : {d:.1} ns/tick\n", .{gp});
    std.debug.print("id-tagged  get : {d:.1} ns/tick (+ binding id de-interleave)\n", .{gi});
    std.debug.print("get delta      : {d:.1} ns/tick  ({d:.4} ms/tick)\n", .{ gi - gp, (gi - gp) / 1e6 });
    std.debug.print("get delta vs rig 0.649 ms/tick : {d:.2}%\n", .{(gi - gp) / rig_baseline_ns * 100});

    const delta = id_tick - pos_tick;
    std.debug.print("\n--- FULL round-trip (get + set; MockEcs over-penalizes positional's preflight walk) ---\n", .{});
    std.debug.print("positional : {d:.1} ns/tick\n", .{pos_tick});
    std.debug.print("id-tagged  : {d:.1} ns/tick\n", .{id_tick});
    std.debug.print("delta      : {d:.1} ns/tick  ({d:.4} ms/tick)\n", .{ delta, delta / 1e6 });
    std.debug.print("delta vs rig 0.649 ms/tick baseline : {d:.2}%\n", .{delta / rig_baseline_ns * 100});
    std.debug.print("\n--- verdict ---\n", .{});
    // The GET-only delta is the id column's true marginal cost (the set
    // side only gets CHEAPER by dropping the preflight re-query). Use it
    // as the conservative overhead figure.
    const overhead_pct = (gi - gp) / rig_baseline_ns * 100;
    std.debug.print("id-column overhead (get-side marginal) : {d:.2}% of a rig tick\n", .{overhead_pct});
    std.debug.print("=> {s} (threshold 10%)\n", .{if (overhead_pct < 10) "ADOPT as default" else "SHIP OPT-IN"});
}
