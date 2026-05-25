//! zspec aggregator for the engine's BDD specs.
//!
//! `zig build spec` (and `zig build test`) roots a test binary here;
//! every `pub const`-exported spec struct is discovered by
//! `zspec.runAll`. Add new spec files as imports + re-exports below.

const zspec = @import("zspec");

pub const unified_format_spec = @import("unified_format_spec.zig");

// Re-export the spec structs so zspec discovers them.
pub const UnifiedFormatSpec = unified_format_spec.UnifiedFormatSpec;

test {
    zspec.runAll(@This());
}
