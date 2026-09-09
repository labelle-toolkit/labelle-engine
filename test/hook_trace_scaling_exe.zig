//! Traced-dispatch SCALING regression (#858, parent #854).
//!
//! `core.MergeHooks.emit` expands `switch (payload) { inline else }` over
//! every event variant and, inside each arm, an `inline for` over every
//! receiver type — a comptime cost that is the PRODUCT `variants x
//! receivers`. It carries `@setEvalBranchQuota(100000)` for exactly that
//! reason, and `test/hook_dispatch_scaling_test.zig` pins it at the #854
//! validation size (64 variants x 16 receivers).
//!
//! Tracing replaces that walk with the engine's own
//! (`src/game/hook_trace_dispatch.zig`), which pays the SAME product plus
//! a constant per iteration — so it is the one change in the hooks epic
//! most likely to blow the budget. This file is the measurement: the same
//! 64 x 16 shape, with tracing switched ON, compiled as an EXECUTABLE
//! (the only compilation shape whose root can carry the opt-in).
//!
//! It deliberately sets no `@setEvalBranchQuota` of its own, so the quota
//! inside `hook_trace_dispatch.dispatch` is the only thing making it
//! compile. If you are reading this because the build failed with
//! "evaluation exceeded N backwards branches", raise the quota THERE.
//!
//! Compiling is most of the test; the runtime half proves the traced
//! fan-out actually ran and recorded, and that receiver-id derivation is
//! memoized per receiver TYPE rather than paid per (receiver x variant).

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

/// The opt-in under measurement.
///
/// `tools/hook_trace_cost.sh` compiles this file a second time with THIS
/// LINE DELETED, which is the untraced twin it times against — every
/// tracer assertion below is behind `if (comptime engine.hookTraceEnabled)`
/// precisely so the same source is a valid A/B pair.
pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 2048 };

/// 64 event variants — the representative project-scale `GameEvents`.
const WideEvents = union(enum) {
    ev_00: struct { n: u32 = 0 },
    ev_01: struct { n: u32 = 0 },
    ev_02: struct { n: u32 = 0 },
    ev_03: struct { n: u32 = 0 },
    ev_04: struct { n: u32 = 0 },
    ev_05: struct { n: u32 = 0 },
    ev_06: struct { n: u32 = 0 },
    ev_07: struct { n: u32 = 0 },
    ev_08: struct { n: u32 = 0 },
    ev_09: struct { n: u32 = 0 },
    ev_10: struct { n: u32 = 0 },
    ev_11: struct { n: u32 = 0 },
    ev_12: struct { n: u32 = 0 },
    ev_13: struct { n: u32 = 0 },
    ev_14: struct { n: u32 = 0 },
    ev_15: struct { n: u32 = 0 },
    ev_16: struct { n: u32 = 0 },
    ev_17: struct { n: u32 = 0 },
    ev_18: struct { n: u32 = 0 },
    ev_19: struct { n: u32 = 0 },
    ev_20: struct { n: u32 = 0 },
    ev_21: struct { n: u32 = 0 },
    ev_22: struct { n: u32 = 0 },
    ev_23: struct { n: u32 = 0 },
    ev_24: struct { n: u32 = 0 },
    ev_25: struct { n: u32 = 0 },
    ev_26: struct { n: u32 = 0 },
    ev_27: struct { n: u32 = 0 },
    ev_28: struct { n: u32 = 0 },
    ev_29: struct { n: u32 = 0 },
    ev_30: struct { n: u32 = 0 },
    ev_31: struct { n: u32 = 0 },
    ev_32: struct { n: u32 = 0 },
    ev_33: struct { n: u32 = 0 },
    ev_34: struct { n: u32 = 0 },
    ev_35: struct { n: u32 = 0 },
    ev_36: struct { n: u32 = 0 },
    ev_37: struct { n: u32 = 0 },
    ev_38: struct { n: u32 = 0 },
    ev_39: struct { n: u32 = 0 },
    ev_40: struct { n: u32 = 0 },
    ev_41: struct { n: u32 = 0 },
    ev_42: struct { n: u32 = 0 },
    ev_43: struct { n: u32 = 0 },
    ev_44: struct { n: u32 = 0 },
    ev_45: struct { n: u32 = 0 },
    ev_46: struct { n: u32 = 0 },
    ev_47: struct { n: u32 = 0 },
    ev_48: struct { n: u32 = 0 },
    ev_49: struct { n: u32 = 0 },
    ev_50: struct { n: u32 = 0 },
    ev_51: struct { n: u32 = 0 },
    ev_52: struct { n: u32 = 0 },
    ev_53: struct { n: u32 = 0 },
    ev_54: struct { n: u32 = 0 },
    ev_55: struct { n: u32 = 0 },
    ev_56: struct { n: u32 = 0 },
    ev_57: struct { n: u32 = 0 },
    ev_58: struct { n: u32 = 0 },
    ev_59: struct { n: u32 = 0 },
    ev_60: struct { n: u32 = 0 },
    ev_61: struct { n: u32 = 0 },
    ev_62: struct { n: u32 = 0 },
    ev_63: struct { n: u32 = 0 },
};

/// 16 distinct receiver types, four handlers each. Every one declares
/// `labelle_receiver_id`, so the trace labels match assembler#723's ids
/// exactly and the derivation path is not what is being measured.
const R00 = struct {
    pub const labelle_receiver_id = "packs/p00/hooks/r00_hooks";
    hits: usize = 0,
    pub fn ev_00(self: *R00, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_01(self: *R00, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_02(self: *R00, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_03(self: *R00, _: anytype) void {
        self.hits += 1;
    }
};
const R01 = struct {
    pub const labelle_receiver_id = "packs/p01/hooks/r01_hooks";
    hits: usize = 0,
    pub fn ev_04(self: *R01, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_05(self: *R01, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_06(self: *R01, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_07(self: *R01, _: anytype) void {
        self.hits += 1;
    }
};
const R02 = struct {
    pub const labelle_receiver_id = "packs/p02/hooks/r02_hooks";
    hits: usize = 0,
    pub fn ev_08(self: *R02, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_09(self: *R02, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_10(self: *R02, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_11(self: *R02, _: anytype) void {
        self.hits += 1;
    }
};
const R03 = struct {
    pub const labelle_receiver_id = "packs/p03/hooks/r03_hooks";
    hits: usize = 0,
    pub fn ev_12(self: *R03, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_13(self: *R03, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_14(self: *R03, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_15(self: *R03, _: anytype) void {
        self.hits += 1;
    }
};
const R04 = struct {
    pub const labelle_receiver_id = "packs/p04/hooks/r04_hooks";
    hits: usize = 0,
    pub fn ev_16(self: *R04, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_17(self: *R04, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_18(self: *R04, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_19(self: *R04, _: anytype) void {
        self.hits += 1;
    }
};
const R05 = struct {
    pub const labelle_receiver_id = "packs/p05/hooks/r05_hooks";
    hits: usize = 0,
    pub fn ev_20(self: *R05, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_21(self: *R05, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_22(self: *R05, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_23(self: *R05, _: anytype) void {
        self.hits += 1;
    }
};
const R06 = struct {
    pub const labelle_receiver_id = "packs/p06/hooks/r06_hooks";
    hits: usize = 0,
    pub fn ev_24(self: *R06, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_25(self: *R06, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_26(self: *R06, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_27(self: *R06, _: anytype) void {
        self.hits += 1;
    }
};
const R07 = struct {
    pub const labelle_receiver_id = "packs/p07/hooks/r07_hooks";
    hits: usize = 0,
    pub fn ev_28(self: *R07, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_29(self: *R07, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_30(self: *R07, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_31(self: *R07, _: anytype) void {
        self.hits += 1;
    }
};
const R08 = struct {
    pub const labelle_receiver_id = "packs/p08/hooks/r08_hooks";
    hits: usize = 0,
    pub fn ev_32(self: *R08, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_33(self: *R08, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_34(self: *R08, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_35(self: *R08, _: anytype) void {
        self.hits += 1;
    }
};
const R09 = struct {
    pub const labelle_receiver_id = "packs/p09/hooks/r09_hooks";
    hits: usize = 0,
    pub fn ev_36(self: *R09, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_37(self: *R09, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_38(self: *R09, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_39(self: *R09, _: anytype) void {
        self.hits += 1;
    }
};
const R10 = struct {
    pub const labelle_receiver_id = "packs/p10/hooks/r10_hooks";
    hits: usize = 0,
    pub fn ev_40(self: *R10, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_41(self: *R10, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_42(self: *R10, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_43(self: *R10, _: anytype) void {
        self.hits += 1;
    }
};
const R11 = struct {
    pub const labelle_receiver_id = "packs/p11/hooks/r11_hooks";
    hits: usize = 0,
    pub fn ev_44(self: *R11, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_45(self: *R11, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_46(self: *R11, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_47(self: *R11, _: anytype) void {
        self.hits += 1;
    }
};
const R12 = struct {
    pub const labelle_receiver_id = "packs/p12/hooks/r12_hooks";
    hits: usize = 0,
    pub fn ev_48(self: *R12, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_49(self: *R12, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_50(self: *R12, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_51(self: *R12, _: anytype) void {
        self.hits += 1;
    }
};
const R13 = struct {
    pub const labelle_receiver_id = "packs/p13/hooks/r13_hooks";
    hits: usize = 0,
    pub fn ev_52(self: *R13, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_53(self: *R13, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_54(self: *R13, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_55(self: *R13, _: anytype) void {
        self.hits += 1;
    }
};
const R14 = struct {
    pub const labelle_receiver_id = "packs/p14/hooks/r14_hooks";
    hits: usize = 0,
    pub fn ev_56(self: *R14, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_57(self: *R14, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_58(self: *R14, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_59(self: *R14, _: anytype) void {
        self.hits += 1;
    }
};
const R15 = struct {
    pub const labelle_receiver_id = "packs/p15/hooks/r15_hooks";
    hits: usize = 0,
    pub fn ev_60(self: *R15, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_61(self: *R15, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_62(self: *R15, _: anytype) void {
        self.hits += 1;
    }
    pub fn ev_63(self: *R15, _: anytype) void {
        self.hits += 1;
    }
};

const WidePayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), WideEvents });
const WideHooks = core.MergeHooks(WidePayload, .{
    *R00,
    *R01,
    *R02,
    *R03,
    *R04,
    *R05,
    *R06,
    *R07,
    *R08,
    *R09,
    *R10,
    *R11,
    *R12,
    *R13,
    *R14,
    *R15,
});

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const MockEcs = core.MockEcsBackend(u32);

const WideGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *WideHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    WideEvents,
);

pub const Game = WideGame;

const Receivers = struct {
    r00: R00 = .{},
    r01: R01 = .{},
    r02: R02 = .{},
    r03: R03 = .{},
    r04: R04 = .{},
    r05: R05 = .{},
    r06: R06 = .{},
    r07: R07 = .{},
    r08: R08 = .{},
    r09: R09 = .{},
    r10: R10 = .{},
    r11: R11 = .{},
    r12: R12 = .{},
    r13: R13 = .{},
    r14: R14 = .{},
    r15: R15 = .{},
};

fn expect(ok: bool, what: []const u8) void {
    if (!ok) {
        std.debug.print("hook_trace_scaling_exe: FAILED: {s}\n", .{what});
        failures += 1;
    }
}

var failures: usize = 0;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var recv = Receivers{};
    var hooks = WideHooks{ .receivers = .{
        &recv.r00,
        &recv.r01,
        &recv.r02,
        &recv.r03,
        &recv.r04,
        &recv.r05,
        &recv.r06,
        &recv.r07,
        &recv.r08,
        &recv.r09,
        &recv.r10,
        &recv.r11,
        &recv.r12,
        &recv.r13,
        &recv.r14,
        &recv.r15,
    } };

    var game = WideGame.init(gpa.allocator());
    defer game.deinit();
    game.setHooks(&hooks);

    // One buffered event per variant, drained together: this instantiates
    // every arm of the traced `inline else` switch AND every receiver
    // probe inside it — the full 64 x 16 comptime product.
    game.emit(.{ .ev_00 = .{ .n = 0 } });
    game.emit(.{ .ev_01 = .{ .n = 1 } });
    game.emit(.{ .ev_02 = .{ .n = 2 } });
    game.emit(.{ .ev_03 = .{ .n = 3 } });
    game.emit(.{ .ev_04 = .{ .n = 4 } });
    game.emit(.{ .ev_05 = .{ .n = 5 } });
    game.emit(.{ .ev_06 = .{ .n = 6 } });
    game.emit(.{ .ev_07 = .{ .n = 7 } });
    game.emit(.{ .ev_08 = .{ .n = 8 } });
    game.emit(.{ .ev_09 = .{ .n = 9 } });
    game.emit(.{ .ev_10 = .{ .n = 10 } });
    game.emit(.{ .ev_11 = .{ .n = 11 } });
    game.emit(.{ .ev_12 = .{ .n = 12 } });
    game.emit(.{ .ev_13 = .{ .n = 13 } });
    game.emit(.{ .ev_14 = .{ .n = 14 } });
    game.emit(.{ .ev_15 = .{ .n = 15 } });
    game.emit(.{ .ev_16 = .{ .n = 16 } });
    game.emit(.{ .ev_17 = .{ .n = 17 } });
    game.emit(.{ .ev_18 = .{ .n = 18 } });
    game.emit(.{ .ev_19 = .{ .n = 19 } });
    game.emit(.{ .ev_20 = .{ .n = 20 } });
    game.emit(.{ .ev_21 = .{ .n = 21 } });
    game.emit(.{ .ev_22 = .{ .n = 22 } });
    game.emit(.{ .ev_23 = .{ .n = 23 } });
    game.emit(.{ .ev_24 = .{ .n = 24 } });
    game.emit(.{ .ev_25 = .{ .n = 25 } });
    game.emit(.{ .ev_26 = .{ .n = 26 } });
    game.emit(.{ .ev_27 = .{ .n = 27 } });
    game.emit(.{ .ev_28 = .{ .n = 28 } });
    game.emit(.{ .ev_29 = .{ .n = 29 } });
    game.emit(.{ .ev_30 = .{ .n = 30 } });
    game.emit(.{ .ev_31 = .{ .n = 31 } });
    game.emit(.{ .ev_32 = .{ .n = 32 } });
    game.emit(.{ .ev_33 = .{ .n = 33 } });
    game.emit(.{ .ev_34 = .{ .n = 34 } });
    game.emit(.{ .ev_35 = .{ .n = 35 } });
    game.emit(.{ .ev_36 = .{ .n = 36 } });
    game.emit(.{ .ev_37 = .{ .n = 37 } });
    game.emit(.{ .ev_38 = .{ .n = 38 } });
    game.emit(.{ .ev_39 = .{ .n = 39 } });
    game.emit(.{ .ev_40 = .{ .n = 40 } });
    game.emit(.{ .ev_41 = .{ .n = 41 } });
    game.emit(.{ .ev_42 = .{ .n = 42 } });
    game.emit(.{ .ev_43 = .{ .n = 43 } });
    game.emit(.{ .ev_44 = .{ .n = 44 } });
    game.emit(.{ .ev_45 = .{ .n = 45 } });
    game.emit(.{ .ev_46 = .{ .n = 46 } });
    game.emit(.{ .ev_47 = .{ .n = 47 } });
    game.emit(.{ .ev_48 = .{ .n = 48 } });
    game.emit(.{ .ev_49 = .{ .n = 49 } });
    game.emit(.{ .ev_50 = .{ .n = 50 } });
    game.emit(.{ .ev_51 = .{ .n = 51 } });
    game.emit(.{ .ev_52 = .{ .n = 52 } });
    game.emit(.{ .ev_53 = .{ .n = 53 } });
    game.emit(.{ .ev_54 = .{ .n = 54 } });
    game.emit(.{ .ev_55 = .{ .n = 55 } });
    game.emit(.{ .ev_56 = .{ .n = 56 } });
    game.emit(.{ .ev_57 = .{ .n = 57 } });
    game.emit(.{ .ev_58 = .{ .n = 58 } });
    game.emit(.{ .ev_59 = .{ .n = 59 } });
    game.emit(.{ .ev_60 = .{ .n = 60 } });
    game.emit(.{ .ev_61 = .{ .n = 61 } });
    game.emit(.{ .ev_62 = .{ .n = 62 } });
    game.emit(.{ .ev_63 = .{ .n = 63 } });
    if (comptime engine.hookTraceEnabled) game.hook_tracer.clear();
    game.dispatchEvents();

    expect(recv.r00.hits == 4, "r00 ran its four handlers");
    expect(recv.r01.hits == 4, "r01 ran its four handlers");
    expect(recv.r02.hits == 4, "r02 ran its four handlers");
    expect(recv.r03.hits == 4, "r03 ran its four handlers");
    expect(recv.r04.hits == 4, "r04 ran its four handlers");
    expect(recv.r05.hits == 4, "r05 ran its four handlers");
    expect(recv.r06.hits == 4, "r06 ran its four handlers");
    expect(recv.r07.hits == 4, "r07 ran its four handlers");
    expect(recv.r08.hits == 4, "r08 ran its four handlers");
    expect(recv.r09.hits == 4, "r09 ran its four handlers");
    expect(recv.r10.hits == 4, "r10 ran its four handlers");
    expect(recv.r11.hits == 4, "r11 ran its four handlers");
    expect(recv.r12.hits == 4, "r12 ran its four handlers");
    expect(recv.r13.hits == 4, "r13 ran its four handlers");
    expect(recv.r14.hits == 4, "r14 ran its four handlers");
    expect(recv.r15.hits == 4, "r15 ran its four handlers");

    if (comptime engine.hookTraceEnabled) {
        // 1 drain_begin + 64 x (dispatch_begin + 1 deliver + dispatch_end)
        // + 1 drain_end.
        expect(game.hook_tracer.count() == 1 + 64 * 3 + 1, "the traced drain recorded every fan-out");
        expect(game.hook_tracer.dropped == 0, "the 2048-record ring held the whole drain");

        // Every delivery is labelled with the receiver's DECLARED id,
        // which is assembler#723's id verbatim.
        var declared: usize = 0;
        for (0..game.hook_tracer.count()) |i| {
            const r = game.hook_tracer.at(i);
            if (r.phase != .deliver) continue;
            expect(r.receiver_id_kind == .declared, "delivery ids come from the receiver's declaration");
            expect(std.mem.startsWith(u8, r.receiver, "packs/p"), "…and read as assembler#723 ids");
            declared += 1;
        }
        expect(declared == 64, "one delivery per variant");
    }

    if (failures != 0) {
        std.debug.print("hook_trace_scaling_exe: {d} check(s) FAILED\n", .{failures});
        return 1;
    }
    const records = if (comptime engine.hookTraceEnabled) game.hook_tracer.count() else 0;
    std.debug.print("hook_trace_scaling_exe: ok (tracing={}, {d} records)\n", .{ engine.hookTraceEnabled, records });
    return 0;
}
