//! Persistent, world-owned two-lane snapshot executor. The simulation thread
//! owns submission and joins each batch before returning. No ECS pointers may
//! appear in a job; each lane writes only its own result range.
const std = @import("std");
const builtin = @import("builtin");
const sleepNs = @import("sleep_helper.zig").sleepNs;

pub const SnapshotExecutor = struct {
    pub const Work = *const fn (*anyopaque, usize, usize) void;
    thread: ?std.Thread = null,
    attempted: bool = false,
    state: std.atomic.Value(u32) = .init(0), // idle / work / stop
    context: *anyopaque = undefined,
    work: Work = undefined,
    end: usize = 0,

    /// Returns whether the worker lane ran. Unsupported targets or spawn
    /// failure execute exactly the same batch serially. Never spawn per item.
    pub fn run(self: *SnapshotExecutor, context: *anyopaque, count: usize, work: Work) bool {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding or builtin.os.tag == .wasi) {
            work(context, 0, count);
            return false;
        }
        if (count < 2) {
            work(context, 0, count);
            return false;
        }
        if (!self.attempted) {
            self.attempted = true;
            self.thread = std.Thread.spawn(.{}, loop, .{self}) catch null;
        }
        if (self.thread == null) {
            work(context, 0, count);
            return false;
        }
        std.debug.assert(self.state.load(.acquire) == 0);
        self.context = context;
        self.work = work;
        self.end = count / 2;
        self.state.store(1, .release);
        work(context, count / 2, count);
        // A late batch waits; eligibility never depends on completion timing.
        while (self.state.load(.acquire) != 0) std.Thread.yield() catch {};
        return true;
    }

    fn loop(self: *SnapshotExecutor) void {
        while (true) {
            switch (self.state.load(.acquire)) {
                0 => sleepNs(100 * std.time.ns_per_us),
                1 => {
                    self.work(self.context, 0, self.end);
                    self.state.store(0, .release);
                },
                else => return,
            }
        }
    }

    /// Caller owns the simulation phase; run has already joined its batch.
    pub fn deinit(self: *SnapshotExecutor) void {
        if (self.thread) |thread| {
            std.debug.assert(self.state.load(.acquire) == 0);
            self.state.store(2, .release);
            thread.join();
            self.thread = null;
        }
    }
};
