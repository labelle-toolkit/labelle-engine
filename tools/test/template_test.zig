const std = @import("std");
const zspec = @import("zspec");

test {
    zspec.runAll(@This());
}

// All main_*.txt templates (flat, used by generator via @embedFile)
const flat_templates = .{
    .{ "main_raylib", @embedFile("../templates/main_raylib.txt") },
    .{ "main_raylib_wasm", @embedFile("../templates/main_raylib_wasm.txt") },
    .{ "main_sokol", @embedFile("../templates/main_sokol.txt") },
    .{ "main_sokol_android", @embedFile("../templates/main_sokol_android.txt") },
    .{ "main_sokol_ios", @embedFile("../templates/main_sokol_ios.txt") },
    .{ "main_wasm", @embedFile("../templates/main_wasm.txt") },
    .{ "main_sdl", @embedFile("../templates/main_sdl.txt") },
    .{ "main_bgfx", @embedFile("../templates/main_bgfx.txt") },
    .{ "main_wgpu_native", @embedFile("../templates/main_wgpu_native.txt") },
};

// All src/main_*.txt templates (with .include directives, kept in sync)
const src_templates = .{
    .{ "src/main_raylib", @embedFile("../templates/src/main_raylib.txt") },
    .{ "src/main_sokol", @embedFile("../templates/src/main_sokol.txt") },
    .{ "src/main_sokol_android", @embedFile("../templates/src/main_sokol_android.txt") },
    .{ "src/main_sokol_ios", @embedFile("../templates/src/main_sokol_ios.txt") },
    .{ "src/main_wasm", @embedFile("../templates/src/main_wasm.txt") },
    .{ "src/main_sdl", @embedFile("../templates/src/main_sdl.txt") },
    .{ "src/main_bgfx", @embedFile("../templates/src/main_bgfx.txt") },
    .{ "src/main_wgpu_native", @embedFile("../templates/src/main_wgpu_native.txt") },
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ---------------------------------------------------------------------------
// Flat templates (tools/templates/main_*.txt)
// ---------------------------------------------------------------------------

pub const FLAT_TEMPLATE_GIZMO_CALLS = struct {
    test "all flat templates contain clearGizmos" {
        inline for (flat_templates) |entry| {
            const name = entry[0];
            const content = entry[1];
            if (!contains(content, "clearGizmos()")) {
                std.debug.print("FAIL: {s} missing clearGizmos()\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }

    test "all flat templates contain renderStandaloneGizmos" {
        inline for (flat_templates) |entry| {
            const name = entry[0];
            const content = entry[1];
            if (!contains(content, "renderStandaloneGizmos()")) {
                std.debug.print("FAIL: {s} missing renderStandaloneGizmos()\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Src templates (tools/templates/src/main_*.txt)
// ---------------------------------------------------------------------------

pub const SRC_TEMPLATE_GIZMO_CALLS = struct {
    test "all src templates contain clearGizmos" {
        inline for (src_templates) |entry| {
            const name = entry[0];
            const content = entry[1];
            if (!contains(content, "clearGizmos()")) {
                std.debug.print("FAIL: {s} missing clearGizmos()\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }

    test "all src templates contain renderStandaloneGizmos" {
        inline for (src_templates) |entry| {
            const name = entry[0];
            const content = entry[1];
            if (!contains(content, "renderStandaloneGizmos()")) {
                std.debug.print("FAIL: {s} missing renderStandaloneGizmos()\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
};
