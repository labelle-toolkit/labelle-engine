//! Scene Module Tests
//!
//! BDD-style tests using zspec for the scene loader module.

const std = @import("std");
const zspec = @import("zspec");

test {
    // Import and run all test modules
    zspec.runAll(@This());

    // Reference all test modules to ensure they're compiled and run
    _ = @import("loader_test.zig");
    _ = @import("nested_prefab_test.zig");
    _ = @import("parent_ref_test.zig");
    _ = @import("entity_ref_test.zig");
    _ = @import("declarative_parent_test.zig");
}
