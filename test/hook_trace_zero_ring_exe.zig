//! `ring_capacity = 0` (sink-only) must still let a caller RENDER (#727/#858 review).
//!
//! Zero capacity is a documented configuration: records are filtered and
//! handed to the sink, nothing is retained. But `Tracer.at` indexes the
//! ring with `% capacity`, and a modulo by a comptime-known zero is a
//! COMPILE error in Zig. `writeText` and `writeJsonLines` both call `at`,
//! so merely instantiating either of them in a zero-capacity build could
//! fail to compile — while the whole-trace dump is exactly what the docs
//! tell a sink-only user to call.
//!
//! Like its siblings this is an executable, because tracing options are
//! read from the COMPILATION ROOT and a `zig test` binary's root is Zig's
//! own test runner. Its value is mostly that it BUILDS: the defect under
//! test is a compile error. The runtime checks below pin the documented
//! zero-capacity contract on top of that — nothing retained, but the
//! counters and the summary still tell the truth.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 0 };

var failures: usize = 0;

fn expect(ok: bool, what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.debug.print("hook_trace_zero_ring_exe: FAIL {s}\n", .{what});
}

pub fn main() !void {
    var tracer: engine.hook_trace.Tracer = .{};

    // Record something. With no ring it is counted and dropped, not kept.
    tracer.push(.{ .phase = .enqueue, .source = .emit, .event = "probe" });
    expect(tracer.count() == 0, "a zero-capacity ring retains nothing");
    expect(tracer.dropped == 1, "a zero-capacity ring counts the drop");
    expect(tracer.seq == 1, "seq advances even with nothing retained");

    // THE POINT OF THE PROBE: both renderers must INSTANTIATE. If `at`
    // is analyzed with `capacity == 0`, this file does not compile.
    var buf: [4096]u8 = undefined;

    var text_w = std.Io.Writer.fixed(&buf);
    try tracer.writeText(&text_w);
    const text = text_w.buffered();
    expect(text.len > 0, "writeText emits a summary even with an empty ring");

    var json_w = std.Io.Writer.fixed(&buf);
    try tracer.writeJsonLines(&json_w);
    const json = json_w.buffered();
    expect(json.len > 0, "writeJsonLines emits a summary even with an empty ring");
    expect(
        std.mem.indexOf(u8, json, "\"capacity\":0") != null,
        "the summary reports the zero capacity honestly",
    );

    if (failures != 0) {
        std.debug.print("hook_trace_zero_ring_exe: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("hook_trace_zero_ring_exe: OK\n", .{});
}
