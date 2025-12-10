// CLI tool for generating project files from project.labelle
//
// Usage:
//   labelle-generate [options] [project_path]
//
// Options:
//   --main-only           Only generate main.zig (not build.zig or build.zig.zon)
//   --all                 Generate all files (default for new projects)
//   --engine-path <path>  Use local path to labelle-engine (for development)
//
// If no path is provided, uses current directory.

const std = @import("std");
const generator = @import("generator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var project_path: []const u8 = ".";
    var main_only = false;
    var engine_path: ?[]const u8 = null;

    // Parse args
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--main-only")) {
            main_only = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            main_only = false;
        } else if (std.mem.eql(u8, arg, "--engine-path")) {
            i += 1;
            if (i < args.len) {
                engine_path = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            engine_path = arg["--engine-path=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    if (main_only) {
        std.debug.print("Generating main.zig for: {s}\n", .{project_path});
        generator.generateMainOnly(allocator, project_path) catch |err| {
            std.debug.print("Error generating main.zig: {}\n", .{err});
            return err;
        };
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - main.zig\n", .{});
    } else {
        std.debug.print("Generating project files for: {s}\n", .{project_path});
        generator.generateProject(allocator, project_path, .{
            .engine_path = engine_path,
        }) catch |err| {
            std.debug.print("Error generating project: {}\n", .{err});
            return err;
        };
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - build.zig.zon\n", .{});
        std.debug.print("  - build.zig\n", .{});
        std.debug.print("  - main.zig\n", .{});
    }
}
