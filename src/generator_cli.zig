// CLI tool for generating project files from project.labelle
//
// Usage:
//   labelle-generate [project_path]
//
// If no path is provided, uses current directory.

const std = @import("std");
const generator = @import("generator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get project path from args or use current directory
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const project_path = if (args.len > 1) args[1] else ".";

    std.debug.print("Generating project files for: {s}\n", .{project_path});

    generator.generateProject(allocator, project_path) catch |err| {
        std.debug.print("Error generating project: {}\n", .{err});
        return err;
    };

    std.debug.print("Generated:\n", .{});
    std.debug.print("  - build.zig.zon\n", .{});
    std.debug.print("  - build.zig\n", .{});
    std.debug.print("  - main.zig\n", .{});
}
