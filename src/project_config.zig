// Project configuration loader for .labelle files
//
// Parses ZON-formatted .labelle project files at runtime using std.zon.parseFromSlice.
// This enables projects to declare metadata, plugins, and other configuration
// in a type-safe, Zig-native format.
//
// Example .labelle file:
//
//   .{
//       .version = 1,
//       .name = "my_game",
//       .created_at = 1733600000,
//       .modified_at = 1733600000,
//       .description = "My awesome game",
//       .plugins = .{
//           .{ .name = "labelle-pathfinding", .version = "0.1.0" },
//           .{ .name = "labelle-serialization", .version = "0.2.0" },
//       },
//   }
//
// Usage:
//
//   const engine = @import("labelle-engine");
//   const config = try engine.ProjectConfig.load(allocator, "project.labelle");
//   defer config.deinit(allocator);
//
//   std.debug.print("Project: {s}\n", .{config.name});
//   for (config.plugins) |plugin| {
//       std.debug.print("  Plugin: {s} v{s}\n", .{plugin.name, plugin.version});
//   }

const std = @import("std");

/// Plugin dependency declaration
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
};

/// Project configuration loaded from .labelle file
pub const ProjectConfig = struct {
    version: u32,
    name: []const u8,
    created_at: i64,
    modified_at: i64,
    description: []const u8,
    plugins: []const Plugin = &.{},

    /// Load project configuration from a .labelle file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !ProjectConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Get file size
        const stat = try file.stat();
        const file_size = stat.size;

        // Allocate sentinel-terminated buffer and read file
        const content = try allocator.allocSentinel(u8, file_size, 0);
        defer allocator.free(content);

        const bytes_read = try file.readAll(content);
        if (bytes_read != file_size) {
            return error.UnexpectedEof;
        }

        return std.zon.parse.fromSlice(ProjectConfig, allocator, content, null, .{});
    }

    /// Free resources allocated during parsing
    pub fn deinit(self: ProjectConfig, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self);
    }
};
