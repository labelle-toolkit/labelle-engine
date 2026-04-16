//! Asset worker thread + bounded SPSC ring buffers.
//!
//! This file pairs two data structures with a background thread:
//!
//! 1. `SpscRing(T, capacity)` — a tiny lock-free single-producer /
//!    single-consumer ring buffer. The main thread produces
//!    `WorkRequest`s on one instance and consumes `WorkResult`s from
//!    another; the worker thread does the mirror. Head/tail are
//!    `std.atomic.Value(u32)` and the ordering follows the usual SPSC
//!    recipe: the producer publishes its write with a
//!    `release` store and the consumer reads the published head with
//!    an `acquire` load (and vice-versa). No mutex, no allocation.
//!
//! 2. `AssetWorker` — a single `std.Thread` that loops over the
//!    request ring, calls `request.vtable.decode` on the snapshot it
//!    pulled, and pushes the outcome onto the result ring. The worker
//!    *never* touches an `AssetEntry` directly; it only sees the
//!    borrowed fields packed into the `WorkRequest`. This is the
//!    threading invariant documented at the top of `catalog.zig`.
//!
//! Ticket #442 will drain the result ring from `AssetCatalog.pump()`
//! and apply the outcome to the matching entry. Until then the rings
//! and the worker are still live: `acquire()` enqueues work on the
//! first `0 → 1` refcount transition, the worker decodes it and
//! parks on the result ring, and `deinit()` joins the worker cleanly
//! after draining any in-flight results via `loader.drop`.
//!
//! ## Ring sizing
//!
//! `ring_capacity` is a power of two so the modulo folds into a mask.
//! 64 covers flying-platform's six atlases with plenty of headroom
//! (see RFC Open Questions §6); revisit when a project actually hits
//! the ceiling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader_mod = @import("loader.zig");

const AssetLoaderVTable = loader_mod.AssetLoaderVTable;
const DecodedPayload = loader_mod.DecodedPayload;

/// Default capacity for the request and result rings. Power of two so
/// `index & (cap - 1)` replaces the modulo. Keep in sync with the RFC.
pub const ring_capacity: u32 = 64;

/// Snapshot handed to the worker thread. Every field is borrowed —
/// `entry_name`, `file_type` and `bytes` all live for the program's
/// entire lifetime (see the `@embedFile` invariant on the catalog),
/// so the worker can read them without touching the catalog.
pub const WorkRequest = struct {
    entry_name: []const u8,
    vtable: *const AssetLoaderVTable,
    file_type: [:0]const u8,
    bytes: []const u8,
};

/// Worker → main message. Either `decoded` is set (success) or
/// `err` is set (failure); `pump()` discriminates and routes to
/// `loader.upload` / `loader.drop` accordingly. Drained in #442.
///
/// `vtable` is carried through from the originating `WorkRequest` so
/// consumers (`deinit` drain, future `pump()`) can drop or upload the
/// payload without a hashmap lookup — and still do the right thing
/// even if the entry was removed between enqueue and dequeue.
pub const WorkResult = struct {
    entry_name: []const u8,
    vtable: *const AssetLoaderVTable,
    decoded: ?DecodedPayload,
    err: ?anyerror,
};

// ---------------------------------------------------------------------
// SpscRing
// ---------------------------------------------------------------------

/// Bounded lock-free single-producer / single-consumer ring buffer.
///
/// - Exactly one thread may call `tryEnqueue`.
/// - Exactly one thread may call `tryDequeue`.
/// - `capacity` must be a power of two.
///
/// Memory ordering:
///
/// - The producer reads its own `head` with `monotonic` (it wrote it),
///   reads the consumer's `tail` with `acquire` (to observe freed
///   slots), writes the payload, then publishes the new head with
///   `release`.
/// - The consumer mirrors: `monotonic` for its own `tail`, `acquire`
///   for the producer's `head` (to observe the published payload),
///   then a `release` store when it advances `tail`.
pub fn SpscRing(comptime T: type, comptime capacity: u32) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("SpscRing capacity must be a power of two");
        }
    }

    return struct {
        const Self = @This();
        const mask: u32 = capacity - 1;
        // Align head and tail to separate cache lines so the producer
        // (writing head) and consumer (writing tail) don't ping-pong a
        // shared cache line on every publish/consume — classic SPSC
        // false-sharing mitigation.
        const cache_line: usize = 64;

        head: std.atomic.Value(u32) align(cache_line) = std.atomic.Value(u32).init(0),
        tail: std.atomic.Value(u32) align(cache_line) = std.atomic.Value(u32).init(0),
        buffer: [capacity]T = undefined,

        pub fn init() Self {
            return .{};
        }

        /// Producer side. Returns `error.QueueFull` if no slot is free.
        pub fn tryEnqueue(self: *Self, item: T) error{QueueFull}!void {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head -% tail == capacity) return error.QueueFull;
            self.buffer[head & mask] = item;
            self.head.store(head +% 1, .release);
        }

        /// Consumer side. Returns `null` if the ring is empty.
        pub fn tryDequeue(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (head == tail) return null;
            const item = self.buffer[tail & mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }

        /// Non-atomic snapshot — only safe from the consumer side or
        /// while both threads are quiesced. Used by `deinit` drain.
        pub fn isEmpty(self: *const Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }
    };
}

// ---------------------------------------------------------------------
// AssetWorker
// ---------------------------------------------------------------------

pub const RequestRing = SpscRing(WorkRequest, ring_capacity);
pub const ResultRing = SpscRing(WorkResult, ring_capacity);

/// Single background worker. Owns neither ring — the catalog holds
/// both and hands pointers to the worker so the main thread can keep
/// enqueueing requests and draining results without extra plumbing.
pub const AssetWorker = struct {
    allocator: Allocator,
    requests: *RequestRing,
    results: *ResultRing,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Worker park time when the request ring is empty. Short enough
    /// to keep latency tight on a bursty load, long enough to stay
    /// below `~1%` CPU while idle.
    const idle_park_ns: u64 = 100 * std.time.ns_per_us;

    pub fn init(
        allocator: Allocator,
        requests: *RequestRing,
        results: *ResultRing,
    ) AssetWorker {
        return .{
            .allocator = allocator,
            .requests = requests,
            .results = results,
        };
    }

    /// Spawns the background thread. Must be called exactly once,
    /// after `init`. Catalogs call this from their own `init`.
    pub fn start(self: *AssetWorker) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signals shutdown and joins the background thread. Idempotent —
    /// safe to call from `deinit` regardless of whether `start`
    /// succeeded. Does NOT drain the result ring; the caller owns
    /// that step so it can invoke `loader.drop` on any in-flight
    /// payload before the allocator goes away.
    pub fn stop(self: *AssetWorker) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *AssetWorker) void {
        while (!self.shutdown.load(.acquire)) {
            const request = self.requests.tryDequeue() orelse {
                std.Thread.sleep(idle_park_ns);
                continue;
            };

            const result = blk: {
                const decoded_or_err = request.vtable.decode(
                    request.file_type,
                    request.bytes,
                    self.allocator,
                );
                if (decoded_or_err) |decoded| {
                    break :blk WorkResult{
                        .entry_name = request.entry_name,
                        .vtable = request.vtable,
                        .decoded = decoded,
                        .err = null,
                    };
                } else |err| {
                    break :blk WorkResult{
                        .entry_name = request.entry_name,
                        .vtable = request.vtable,
                        .decoded = null,
                        .err = err,
                    };
                }
            };

            // The result ring is the same size as the request ring, so
            // a full result ring implies the main thread has not
            // drained in a very long time. Spin until space is free or
            // shutdown is requested — dropping a decoded payload
            // silently here would leak the allocator-owned pixels.
            while (true) {
                if (self.results.tryEnqueue(result)) |_| {
                    break;
                } else |_| {
                    if (self.shutdown.load(.acquire)) {
                        // Shutdown path: hand the payload back to the
                        // loader's drop hook so the allocator can
                        // reclaim it before the catalog tears down.
                        if (result.decoded) |payload| {
                            request.vtable.drop(self.allocator, payload);
                        }
                        return;
                    }
                    std.Thread.sleep(idle_park_ns);
                }
            }
        }
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "SpscRing empty dequeue returns null" {
    var ring = SpscRing(u32, 4).init();
    try testing.expectEqual(@as(?u32, null), ring.tryDequeue());
}

test "SpscRing fills to capacity then returns QueueFull" {
    var ring = SpscRing(u32, 4).init();
    try ring.tryEnqueue(10);
    try ring.tryEnqueue(20);
    try ring.tryEnqueue(30);
    try ring.tryEnqueue(40);
    try testing.expectError(error.QueueFull, ring.tryEnqueue(50));

    try testing.expectEqual(@as(?u32, 10), ring.tryDequeue());
    try ring.tryEnqueue(50); // slot freed
    try testing.expectEqual(@as(?u32, 20), ring.tryDequeue());
    try testing.expectEqual(@as(?u32, 30), ring.tryDequeue());
    try testing.expectEqual(@as(?u32, 40), ring.tryDequeue());
    try testing.expectEqual(@as(?u32, 50), ring.tryDequeue());
    try testing.expectEqual(@as(?u32, null), ring.tryDequeue());
}

test "SpscRing preserves order across producer/consumer threads" {
    const Ring = SpscRing(u32, 8);
    var ring = Ring.init();

    const total: u32 = 10_000;

    const Producer = struct {
        fn run(r: *Ring, n: u32) void {
            var i: u32 = 0;
            while (i < n) {
                r.tryEnqueue(i) catch {
                    std.Thread.yield() catch {};
                    continue;
                };
                i += 1;
            }
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{ &ring, total });

    var expected: u32 = 0;
    while (expected < total) {
        if (ring.tryDequeue()) |value| {
            try testing.expectEqual(expected, value);
            expected += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
    producer.join();
    try testing.expect(ring.isEmpty());
}

test "AssetWorker decodes a stub request and publishes a result" {
    const image_loader = @import("loaders/image.zig");
    // Leave the image backend unset so the real loader surfaces its
    // "not initialised" error instead of actually decoding bytes.
    image_loader.clearBackend();

    var requests = RequestRing.init();
    var results = ResultRing.init();

    var worker = AssetWorker.init(testing.allocator, &requests, &results);
    try worker.start();
    defer worker.stop();

    try requests.tryEnqueue(.{
        .entry_name = "stub",
        .vtable = &image_loader.vtable,
        .file_type = "png",
        .bytes = "not-really-png",
    });

    // Spin up to 200ms waiting for the worker to publish.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    const result = while (waited_ns < deadline_ns) {
        if (results.tryDequeue()) |r| break r;
        std.Thread.sleep(step_ns);
        waited_ns += step_ns;
    } else {
        return error.WorkerDidNotRespond;
    };

    try testing.expectEqualStrings("stub", result.entry_name);
    try testing.expectEqual(@as(?DecodedPayload, null), result.decoded);
    try testing.expectEqual(@as(?anyerror, error.ImageBackendNotInitialized), result.err);
}

test "AssetWorker shuts down cleanly with a request still in flight" {
    var requests = RequestRing.init();
    var results = ResultRing.init();

    var worker = AssetWorker.init(testing.allocator, &requests, &results);
    try worker.start();

    const image_loader = @import("loaders/image.zig");
    // Drop a pending request in and immediately stop without draining.
    try requests.tryEnqueue(.{
        .entry_name = "pending",
        .vtable = &image_loader.vtable,
        .file_type = "png",
        .bytes = "",
    });

    worker.stop(); // must not deadlock, must not leak
    // The result may or may not have landed depending on scheduling;
    // either way we should be able to drain what's there without
    // tripping the testing allocator.
    while (results.tryDequeue()) |_| {}
}
