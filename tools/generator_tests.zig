//! Generator Module Tests
//!
//! BDD-style tests using zspec for the generator submodules.
//! Root placed at tools/ level so relative imports from scanner.zig
//! to project_config.zig resolve within the module path.

const zspec = @import("zspec");

test {
    zspec.runAll(@This());

    _ = @import("test/version_test.zig");
    _ = @import("test/utils_test.zig");
    _ = @import("test/fingerprint_test.zig");
    _ = @import("test/scanner_test.zig");
}
