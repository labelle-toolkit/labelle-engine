// Example 7: Third-Party Plugin Integration
//
// Demonstrates:
// - Loading project configuration from .labelle file (ZON format)
// - Runtime ZON parsing with std.zon.parseFromSlice
// - Project configuration with plugin declarations
//
// The .labelle file format uses ZON syntax, enabling type-safe project configuration
// that can declare plugins/dependencies for the labelle-gui to process.

const std = @import("std");
const engine = @import("labelle-engine");

const ProjectConfig = engine.ProjectConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("labelle-engine Example 7: Third-Party Plugin Integration\n", .{});
    std.debug.print("=========================================================\n\n", .{});

    // Step 1: Load project configuration from .labelle file
    std.debug.print("Step 1: Loading project.labelle (ZON format)\n", .{});
    std.debug.print("---------------------------------------------\n", .{});

    const project = ProjectConfig.load(allocator, "project.labelle") catch |err| {
        std.debug.print("  Error loading project.labelle: {}\n", .{err});
        std.debug.print("  Make sure to run from the example_7 directory\n", .{});
        return err;
    };
    defer project.deinit(allocator);

    std.debug.print("  Project: {s}\n", .{project.name});
    std.debug.print("  Version: {d}\n", .{project.version});
    std.debug.print("  Description: {s}\n", .{project.description});
    std.debug.print("  Created: {d}\n", .{project.created_at});
    std.debug.print("  Modified: {d}\n", .{project.modified_at});
    std.debug.print("\n", .{});

    // Step 2: Display declared plugins
    std.debug.print("Step 2: Plugin declarations\n", .{});
    std.debug.print("---------------------------\n", .{});

    if (project.plugins.len == 0) {
        std.debug.print("  No plugins declared\n", .{});
    } else {
        std.debug.print("  Declared plugins ({d}):\n", .{project.plugins.len});
        for (project.plugins) |plugin| {
            std.debug.print("    - {s} v{s}\n", .{ plugin.name, plugin.version });
        }
    }
    std.debug.print("\n", .{});

    // Step 3: Explain how plugins would be integrated
    std.debug.print("Step 3: Plugin integration workflow\n", .{});
    std.debug.print("-----------------------------------\n", .{});
    std.debug.print("  When labelle-gui processes this project:\n", .{});
    std.debug.print("  1. Read project.labelle to get plugin list\n", .{});
    std.debug.print("  2. Generate build.zig.zon with plugin dependencies\n", .{});
    std.debug.print("  3. Plugins are available via @import in game code\n", .{});
    std.debug.print("\n", .{});

    // Summary
    std.debug.print("Summary\n", .{});
    std.debug.print("-------\n", .{});
    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("  - .labelle files use ZON format (Zig Object Notation)\n", .{});
    std.debug.print("  - Runtime parsing via std.zon.parse.fromSlice\n", .{});
    std.debug.print("  - Type-safe project configuration with ProjectConfig\n", .{});
    std.debug.print("  - Plugin declarations for third-party library integration\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Example 7 completed successfully!\n", .{});
}
