// Project configuration loader for .labelle files
//
// Parses ZON-formatted .labelle project files at runtime using std.zon.parse.fromSlice.
// This enables projects to declare metadata, plugins, window settings, and the initial
// scene in a type-safe, Zig-native format.
//
// Example .labelle file:
//
//   .{
//       .version = 1,
//       .name = "my_game",
//       .description = "My awesome game",
//       .initial_scene = "main_menu",
//       .backend = .raylib,  // or .sokol
//       .window = .{
//           .width = 800,
//           .height = 600,
//           .title = "My Game",
//       },
//       .plugins = .{
//           .{ .name = "labelle-pathfinding", .version = "0.1.0" },
//       },
//   }
//
// Usage:
//
//   const engine = @import("labelle-engine");
//   try engine.run("project.labelle");

const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
};

/// Plugin dependency declaration
pub const Plugin = struct {
    name: []const u8,
    version: []const u8,
};

/// Atlas resource declaration
pub const Atlas = struct {
    name: []const u8,
    json: [:0]const u8,
    texture: [:0]const u8,
};

/// Resources configuration
pub const Resources = struct {
    atlases: []const Atlas = &.{},
};

/// Window configuration for the project
pub const WindowConfig = struct {
    width: i32 = 800,
    height: i32 = 600,
    title: []const u8 = "labelle Game",
    target_fps: i32 = 60,
    resizable: bool = false,
};

/// Project configuration loaded from .labelle file
pub const ProjectConfig = struct {
    version: u32,
    name: []const u8,
    description: []const u8 = "",
    initial_scene: []const u8,
    backend: Backend = .raylib,
    window: WindowConfig = .{},
    resources: Resources = .{},
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
