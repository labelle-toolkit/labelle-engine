// Project configuration loader for .labelle files
//
// Parses ZON-formatted .labelle project files at runtime using std.zon.parse.fromSlice.
// This enables projects to declare metadata, plugins, window settings, camera settings,
// and the initial scene in a type-safe, Zig-native format.
//
// Example .labelle file:
//
//   .{
//       .version = 1,
//       .name = "my_game",
//       .description = "My awesome game",
//       .initial_scene = "main_menu",
//       .backend = .raylib,      // or .sokol
//       .ecs_backend = .zig_ecs, // or .zflecs (default: .zig_ecs)
//       .window = .{
//           .width = 800,
//           .height = 600,
//           .title = "My Game",
//       },
//       .camera = .{
//           .x = 0,        // Center at origin (default: auto-center on screen)
//           .y = 0,
//           .zoom = 1.0,   // 1.0 = 100% zoom
//       },
//       .plugins = .{
//           .{ .name = "labelle-pathfinding", .version = "2.5.0", .module = "pathfinding" },
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

/// ECS backend selection
pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
};

/// Plugin dependency declaration
pub const Plugin = struct {
    name: []const u8,

    // Reference type (mutually exclusive, exactly one required)
    /// Version tag reference (generates #v{version})
    version: ?[]const u8 = null,
    /// Branch reference (generates #{branch})
    branch: ?[]const u8 = null,
    /// Commit SHA reference (generates #{commit}). Must be 7-40 hex characters.
    commit: ?[]const u8 = null,

    /// GitHub repository URL (e.g., "github.com/labelle-toolkit/labelle-pathfinding")
    /// If not provided, defaults to "github.com/labelle-toolkit/{name}"
    /// Must be host/path format without scheme (no "https://")
    url: ?[]const u8 = null,
    /// Module name exported by the package (e.g., "pathfinding" for labelle-pathfinding)
    /// If not provided, defaults to the plugin name with hyphens replaced by underscores
    module: ?[]const u8 = null,
    /// Components type exported by the plugin. If null, no Components are included.
    /// Examples:
    ///   - null: don't include any Components from this plugin (default)
    ///   - "Components": use plugin.Components
    ///   - "Components(MyItem)": use plugin.Components(MyItem) for parameterized types
    components: ?[]const u8 = null,

    /// Validate the plugin configuration
    pub fn validate(self: Plugin) PluginValidationError!void {
        // Name must be non-empty
        if (self.name.len == 0) {
            return PluginValidationError.EmptyName;
        }

        // Count how many ref types are set
        var ref_count: u8 = 0;
        if (self.version != null) ref_count += 1;
        if (self.branch != null) ref_count += 1;
        if (self.commit != null) ref_count += 1;

        if (ref_count == 0) {
            return PluginValidationError.NoRefSpecified;
        }
        if (ref_count > 1) {
            return PluginValidationError.MultipleRefsSpecified;
        }

        // Validate commit format if specified (7-40 hex characters)
        if (self.commit) |commit_sha| {
            if (commit_sha.len < 7 or commit_sha.len > 40) {
                return PluginValidationError.InvalidCommitLength;
            }
            for (commit_sha) |c| {
                if (!std.ascii.isHex(c)) {
                    return PluginValidationError.InvalidCommitFormat;
                }
            }
        }

        // Validate URL format if specified (must not have scheme)
        if (self.url) |url_str| {
            if (std.mem.startsWith(u8, url_str, "https://") or
                std.mem.startsWith(u8, url_str, "http://") or
                std.mem.startsWith(u8, url_str, "git+https://"))
            {
                return PluginValidationError.UrlContainsScheme;
            }
        }
    }

    /// Get the git reference string for URL generation
    pub fn getRef(self: Plugin) []const u8 {
        if (self.commit) |c| return c;
        if (self.branch) |b| return b;
        // version is prefixed with 'v' in the generator
        return self.version.?;
    }

    /// Check if this plugin uses a version tag (vs branch/commit)
    pub fn isVersionRef(self: Plugin) bool {
        return self.version != null;
    }
};

pub const PluginValidationError = error{
    EmptyName,
    NoRefSpecified,
    MultipleRefsSpecified,
    InvalidCommitLength,
    InvalidCommitFormat,
    UrlContainsScheme,
};

/// Atlas resource declaration
pub const Atlas = struct {
    name: []const u8,
    json: [:0]const u8,
    texture: [:0]const u8,
};

/// Camera configuration for initial camera state
pub const CameraConfig = struct {
    /// Initial camera X position. If null, camera auto-centers on screen.
    x: ?f32 = null,
    /// Initial camera Y position. If null, camera auto-centers on screen.
    y: ?f32 = null,
    /// Initial zoom level (1.0 = 100%)
    zoom: f32 = 1.0,
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
    ecs_backend: EcsBackend = .zig_ecs,
    window: WindowConfig = .{},
    camera: CameraConfig = .{},
    resources: Resources = .{},
    plugins: []const Plugin = &.{},
    /// Output directory for generated build files (build.zig, build.zig.zon)
    /// Relative to the project root. Default: ".labelle"
    /// Note: main.zig stays in the project root for module import compatibility.
    output_dir: ?[]const u8 = null,

    /// Get the output directory (uses default ".labelle" if not specified)
    pub fn getOutputDir(self: ProjectConfig) []const u8 {
        return self.output_dir orelse ".labelle";
    }

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

        const config = try std.zon.parse.fromSlice(ProjectConfig, allocator, content, null, .{});

        // Validate all plugins
        for (config.plugins) |plugin| {
            try plugin.validate();
        }

        return config;
    }

    /// Free resources allocated during parsing
    pub fn deinit(self: ProjectConfig, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self);
    }
};
