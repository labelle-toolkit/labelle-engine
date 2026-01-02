//! Core Module Tests
//!
//! BDD-style tests using zspec for labelle-core.

const std = @import("std");
const zspec = @import("zspec");

test {
    // Import and run all test modules
    zspec.runAll(@This());

    // Reference all test modules to ensure they're compiled and run
    _ = @import("zon_coercion_test.zig");
}
