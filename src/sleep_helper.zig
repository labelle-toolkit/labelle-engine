//! Thread sleep helper for asset workers.
//!
//! std.Thread.sleep was removed in Zig 0.16. This helper uses libc
//! nanosleep on POSIX and Win32 Sleep on Windows so the asset worker
//! threads (catalog/worker) can park briefly between dequeues.
const std = @import("std");
const builtin = @import("builtin");

pub fn sleepNs(ns: u64) void {
    if (builtin.os.tag == .windows) {
        const K = struct { extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void; };
        const ms = @as(u32, @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u32))));
        K.Sleep(ms);
        return;
    }
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    while (true) {
        const rc = std.c.nanosleep(&req, &rem);
        if (rc == 0) return;
        // EINTR — retry with remaining duration.
        req = rem;
    }
}
