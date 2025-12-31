const std = @import("std");
const zspec = @import("zspec");

test {
    // Import and run all test modules
    zspec.runAll(@This());

    // Reference all test modules to ensure they're compiled and run
    _ = @import("prefab_test.zig");
    _ = @import("component_test.zig");
    _ = @import("script_test.zig");
    _ = @import("loader_test.zig");
    _ = @import("scene_test.zig");
    _ = @import("render_pipeline_test.zig");
    _ = @import("nested_prefab_test.zig");
    _ = @import("input_test.zig");
    _ = @import("audio_test.zig");
    _ = @import("game_test.zig");
    _ = @import("hooks_test.zig");
    _ = @import("project_config_test.zig");
    _ = @import("component_callbacks_test.zig");
    _ = @import("query_test.zig");
}
