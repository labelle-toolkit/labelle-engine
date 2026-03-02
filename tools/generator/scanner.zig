const std = @import("std");
const project_config = @import("../project_config.zig");

// =============================================================================
// Folder Scanning
// =============================================================================

/// Scan a folder for .zig files and return their names (without extension)
pub fn scanFolder(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    return scanFolderWithExtension(allocator, path, ".zig");
}

/// Scan a folder for .zon files and return their names (without extension)
pub fn scanZonFolder(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    return scanFolderWithExtension(allocator, path, ".zon");
}

/// Scan a folder for files with a specific extension and return their names (without extension)
fn scanFolderWithExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return names.toOwnedSlice(allocator);
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, extension)) {
            const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - extension.len]);
            try names.append(allocator, name);
        }
    }

    return names.toOwnedSlice(allocator);
}

// =============================================================================
// Type Name Extraction
// =============================================================================

/// Extract the first `pub const` type name from a .zig source file.
/// Looks for patterns like `pub const Foo = struct {`, `pub const Bar = union(enum) {`, etc.
/// Returns the extracted name, or falls back to PascalCase of the filename.
fn extractFirstPubConst(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8) ![]const u8 {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ dir_path, filename });
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return fallbackPascalCase(allocator, filename);
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return fallbackPascalCase(allocator, filename); // Skip files > 1MB

    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const bytes_read = try file.readAll(content);
    const source = content[0..bytes_read];

    // Search for `pub const <Name> =` pattern
    const prefix = "pub const ";
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, source, offset, prefix)) |pos| {
        const name_start = pos + prefix.len;
        if (name_start >= source.len) break;

        // Find the end of the identifier
        var name_end = name_start;
        while (name_end < source.len and (std.ascii.isAlphanumeric(source[name_end]) or source[name_end] == '_')) {
            name_end += 1;
        }

        if (name_end > name_start) {
            const name = source[name_start..name_end];

            // Skip to '=' after whitespace
            var eq_pos = name_end;
            while (eq_pos < source.len and source[eq_pos] == ' ') eq_pos += 1;

            if (eq_pos < source.len and source[eq_pos] == '=') {
                // Skip whitespace after '='
                var after_eq = eq_pos + 1;
                while (after_eq < source.len and source[after_eq] == ' ') after_eq += 1;

                // Check if it's a type definition (struct, union, enum)
                if (after_eq < source.len) {
                    const rest = source[after_eq..];
                    if (std.mem.startsWith(u8, rest, "struct") or
                        std.mem.startsWith(u8, rest, "union") or
                        std.mem.startsWith(u8, rest, "enum"))
                    {
                        return try allocator.dupe(u8, name);
                    }
                }
            }
        }

        offset = name_start + 1;
    }

    return fallbackPascalCase(allocator, filename);
}

/// Fallback: convert filename to PascalCase
fn fallbackPascalCase(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const utils = @import("utils.zig");
    const pascal = try utils.toPascalCase(filename);
    return try allocator.dupe(u8, pascal.buf[0..pascal.len]);
}

/// Extract type names for a list of filenames in a directory.
/// Returns a parallel array where result[i] is the type name for filenames[i].
pub fn extractTypeNames(allocator: std.mem.Allocator, dir_path: []const u8, filenames: []const []const u8) ![]const []const u8 {
    var type_names = try allocator.alloc([]const u8, filenames.len);
    var initialized: usize = 0;
    errdefer {
        for (type_names[0..initialized]) |name| {
            allocator.free(name);
        }
        allocator.free(type_names);
    }

    for (filenames) |filename| {
        type_names[initialized] = try extractFirstPubConst(allocator, dir_path, filename);
        initialized += 1;
    }

    return type_names;
}

// =============================================================================
// Task Hook Scanning
// =============================================================================

/// Known task hook function names that trigger TaskEngine generation
pub const task_hook_names = [_][]const u8{
    "pickup_started",
    "process_started",
    "store_started",
    "worker_released",
};

/// Result of scanning for task hooks
pub const TaskHookScanResult = struct {
    /// Whether any task hooks were found
    has_task_hooks: bool,
    /// List of hook file names that contain task hooks
    hook_files_with_tasks: []const []const u8,
    /// The labelle-tasks plugin config (if found)
    tasks_plugin: ?project_config.Plugin,

    pub fn deinit(self: *TaskHookScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.hook_files_with_tasks);
    }
};

/// Scan hook files for task hook function declarations.
/// Returns information about which files contain task hooks.
pub fn scanForTaskHooks(
    allocator: std.mem.Allocator,
    hooks_path: []const u8,
    hook_files: []const []const u8,
    config: project_config.ProjectConfig,
) !TaskHookScanResult {
    var files_with_tasks: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer files_with_tasks.deinit(allocator);

    // Find the labelle-tasks plugin if configured
    var tasks_plugin: ?project_config.Plugin = null;
    for (config.plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, "labelle-tasks")) {
            tasks_plugin = plugin;
            break;
        }
    }

    // Scan each hook file for task hook function declarations
    for (hook_files) |hook_name| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ hooks_path, hook_name });
        defer allocator.free(file_path);

        if (try fileContainsTaskHooks(allocator, file_path)) {
            try files_with_tasks.append(allocator, hook_name);
        }
    }

    return .{
        .has_task_hooks = files_with_tasks.items.len > 0,
        .hook_files_with_tasks = try files_with_tasks.toOwnedSlice(allocator),
        .tasks_plugin = tasks_plugin,
    };
}

/// Check if a file contains any task hook function declarations.
fn fileContainsTaskHooks(allocator: std.mem.Allocator, file_path: []const u8) !bool {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer file.close();

    // Read file content
    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return false; // Skip files > 1MB

    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const bytes_read = try file.readAll(content);

    // Look for task hook function declarations
    // Pattern: "pub fn <hook_name>("
    var pattern_buf: [128]u8 = undefined;
    for (task_hook_names) |hook_name| {
        const pattern = std.fmt.bufPrint(&pattern_buf, "pub fn {s}(", .{hook_name}) catch continue;

        if (std.mem.indexOf(u8, content[0..bytes_read], pattern) != null) {
            return true;
        }
    }

    return false;
}
