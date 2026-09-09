//! Traced hook fan-out (#858).
//!
//! In an UNTRACED build the engine hands the payload straight to
//! `labelle-core`'s dispatcher (`MergeHooks.emit` / `HookDispatcher.emit`)
//! exactly as it always has, and none of this file is instantiated.
//!
//! In a traced build the engine walks the receiver tuple itself so it can
//! record which handler ran, in which tuple position, and — on a
//! consumable event — which one stopped propagation. Core's dispatcher
//! exposes no per-receiver seam, and #858 is an engine-side ticket, so
//! the walk is reproduced here rather than pushed into core.
//!
//! **The two walks must stay identical.** `walkMerged` below is a
//! line-for-line mirror of `labelle-core/src/dispatcher.zig`'s
//! `MergeHooks.emit`: same tuple order, same `@hasDecl` gate, same
//! consumable break, same discard of a notification handler's return
//! value. `test/hook_trace_root_exe.zig` runs the SAME scenario with
//! tracing on and with tracing off and requires byte-identical handler
//! order and identical game state — that test is what defends the
//! mirror, and it is the reason a change to core's dispatch loop must be
//! mirrored here.

const std = @import("std");
const core = @import("labelle-core");
const trace = @import("../hook_trace.zig");

/// Fan `payload` out to every receiver that declares a handler for its
/// active variant, recording the dispatch as it goes.
///
/// `h` is whatever `Game.hooks` holds: a `*MergeHooks(...)` for an
/// assembled multi-receiver game, or a `HookDispatcher(...)` value for
/// the single-receiver unit-test shape.
pub fn dispatch(
    comptime Game: type,
    self: *Game,
    h: anytype,
    payload: Game.PayloadExport,
    comptime source: trace.Source,
) void {
    // ── Comptime budget (MEASURED, #858) ───────────────────────────
    //
    // This function expands `switch (payload) { inline else }` over every
    // variant, exactly as `core.MergeHooks.emit` does. The per-receiver
    // walk, however, lives in `walkMerged` — a SEPARATE function,
    // instantiated once per variant. That split is load-bearing:
    //
    //   * as written, the 64-variant x 16-receiver shape of
    //     `test/hook_trace_scaling_exe.zig` compiles with NO quota at
    //     all — each `walkMerged` instantiation is its own analysis unit
    //     with its own budget, so the cost is O(variants) per unit
    //     instead of the O(variants x receivers) product;
    //   * marking `walkMerged`/`walkSingle` `inline` folds them back
    //     into this switch and immediately reproduces
    //     "evaluation exceeded 1000 backwards branches" at that same
    //     scale (verified against origin/main + this file).
    //
    // So: do NOT inline the walks. The quota below is headroom for hook
    // surfaces well past #854's validation size, not something the
    // shipped scale needs — which is the opposite of core's 100k, where
    // `test/hook_dispatch_scaling_test.zig` proves the quota IS the only
    // thing making 64 x 16 compile.
    @setEvalBranchQuota(100000);

    const t: *trace.Tracer = &self.hook_tracer;
    const frame = self.frame_number;
    const drain = t.drain_seq;

    switch (payload) {
        inline else => |data, tag| {
            const name = @tagName(tag);
            const VariantType = @TypeOf(data);
            const variant_consumable = comptime trace.isConsumable(VariantType);

            var payload_buf: [trace.options.payload_capacity]u8 = undefined;
            var payload_len: u16 = 0;
            if (comptime trace.options.payload_capacity > 0) {
                if (t.capture_payloads) {
                    payload_len = trace.renderScalars(VariantType, data, &payload_buf);
                }
            }

            t.push(.{
                .phase = .dispatch_begin,
                .source = source,
                .event = name,
                .frame = frame,
                .drain = drain,
                .consumable = variant_consumable,
                .payload_len = payload_len,
                .payload_buf = payload_buf,
            });

            var ran: u32 = 0;
            if (comptime Game.HooksIsMergedExport) {
                ran = walkMerged(t, h, name, data, variant_consumable, source, frame, drain);
            } else {
                ran = walkSingle(Game, t, h, name, data, source, frame, drain);
            }

            t.push(.{
                .phase = .dispatch_end,
                .source = source,
                .event = name,
                .frame = frame,
                .drain = drain,
                .consumable = variant_consumable,
                .count = ran,
            });
        },
    }
}

/// Mirror of `core.MergeHooks.emit`'s receiver loop. Returns the number
/// of handlers that ran.
///
/// **Not `inline`, deliberately.** See the budget note in `dispatch`:
/// one instantiation per variant is what keeps the comptime cost linear
/// instead of `variants x receivers`.
fn walkMerged(
    t: *trace.Tracer,
    h: anytype,
    comptime name: []const u8,
    data: anytype,
    comptime variant_consumable: bool,
    comptime source: trace.Source,
    frame: u64,
    drain: u64,
) u32 {
    const merged = h.*;
    const Receivers = @TypeOf(merged.receivers);
    var ran: u32 = 0;
    inline for (0..std.meta.fields(Receivers).len) |i| {
        const recv = merged.receivers[i];
        const Base = core.UnwrapReceiver(@TypeOf(recv));
        if (comptime @hasDecl(Base, name)) {
            const Id = trace.ReceiverId(Base);
            // Recorded BEFORE the call, so anything the handler itself
            // emits shows up after this record — which is what makes a
            // handler-emitted event legible in the trace.
            t.push(.{
                .phase = .deliver,
                .source = source,
                .event = name,
                .frame = frame,
                .drain = drain,
                .receiver = Id.id,
                .receiver_type = Id.type_name,
                .receiver_id_kind = Id.kind,
                .index = @intCast(i),
                .consumable = variant_consumable,
            });
            ran += 1;
            if (variant_consumable) {
                const handled = @field(Base, name)(recv, data);
                if (handled) {
                    t.push(.{
                        .phase = .consumed,
                        .source = source,
                        .event = name,
                        .frame = frame,
                        .drain = drain,
                        .receiver = Id.id,
                        .receiver_type = Id.type_name,
                        .receiver_id_kind = Id.kind,
                        .index = @intCast(i),
                        .consumable = true,
                    });
                    break;
                }
            } else {
                _ = @field(Base, name)(recv, data);
            }
        }
    }
    return ran;
}

/// Mirror of `core.HookDispatcher.emit` — one receiver, return value
/// discarded (there is no loop to break out of). Not `inline`, for the
/// same reason as `walkMerged`.
fn walkSingle(
    comptime Game: type,
    t: *trace.Tracer,
    h: anytype,
    comptime name: []const u8,
    data: anytype,
    comptime source: trace.Source,
    frame: u64,
    drain: u64,
) u32 {
    const Base = core.UnwrapReceiver(Game.HooksParam);
    if (comptime !@hasDecl(Base, name)) return 0;
    const Id = trace.ReceiverId(Base);
    t.push(.{
        .phase = .deliver,
        .source = source,
        .event = name,
        .frame = frame,
        .drain = drain,
        .receiver = Id.id,
        .receiver_type = Id.type_name,
        .receiver_id_kind = Id.kind,
        .index = 0,
    });
    _ = @field(Base, name)(h.receiver, data);
    return 1;
}
