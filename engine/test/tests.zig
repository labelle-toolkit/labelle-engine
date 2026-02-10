//! Engine Module Tests
//!
//! BDD-style tests using zspec for the engine module.

const std = @import("std");
const zspec = @import("zspec");

test {
    // Import and run all test modules
    zspec.runAll(@This());

    // Reference all test modules to ensure they're compiled and run
    _ = @import("game_test.zig");
    _ = @import("hierarchy_test.zig");
    _ = @import("position_test.zig");
    _ = @import("gizmo_test.zig");
    _ = @import("gizmo_behavior_test.zig");
}
