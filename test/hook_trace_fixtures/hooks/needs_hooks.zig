//! A hook receiver living in a SUBDIRECTORY, so `@typeName` has the
//! module-relative path shape an assembler-generated tree produces
//! (`hook_trace_fixtures.hooks.needs_hooks.NeedsHooks`).
//!
//! This is what `hook_trace.ReceiverId` derives an assembler#723-shaped
//! id from when a receiver does NOT declare `labelle_receiver_id`. The
//! harness asserts the derived id is exactly
//! `hook_trace_fixtures/hooks/needs_hooks` — path relative to the module
//! root (`test/`), `.zig` dropped — which is #723's rule applied to this
//! tree.

const Order = @import("../order.zig");

pub const NeedsHooks = struct {
    order: *Order.Log,
    claims: bool = false,

    pub fn t__alpha(self: *NeedsHooks, _: anytype) void {
        self.order.push("needs:alpha");
    }
    pub fn t__chain_dst(self: *NeedsHooks, _: anytype) void {
        self.order.push("needs:chain_dst");
    }
    pub fn t__claim(self: *NeedsHooks, _: anytype) bool {
        self.order.push("needs:claim");
        return self.claims;
    }
};
