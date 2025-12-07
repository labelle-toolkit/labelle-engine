// Build helpers for GUI-generated project folder scanning
//
// This module provides build-time functions to scan folders and generate
// module imports for scripts, components, and prefabs.
//
// Example usage in build.zig:
//
//   const build_helpers = @import("labelle-engine").build_helpers;
//
//   // Scan folders and add to module
//   build_helpers.addScriptsFolder(b, root_module, "scripts");
//   build_helpers.addComponentsFolder(b, root_module, "components");
//   build_helpers.addPrefabsFolder(b, root_module, "prefabs");

const std = @import("std");
const Build = std.Build;

/// Scan a folder for .zig files and add them as anonymous imports to a module
/// This is useful for build.zig to auto-discover scripts/components/prefabs
pub fn addFolderImports(
    b: *Build,
    module: *Build.Module,
    folder_path: []const u8,
    import_prefix: []const u8,
) void {
    const dir = std.fs.cwd().openDir(folder_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            // Strip .zig extension for import name
            const name = entry.name[0 .. entry.name.len - 4];

            // Create import name: prefix/name (e.g., "scripts/gravity")
            const import_name = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ import_prefix, name }) catch continue;

            // Create source file path
            const source_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ folder_path, entry.name }) catch continue;

            module.addImport(import_name, b.createModule(.{
                .root_source_file = .{ .cwd_relative = source_path },
            }));
        }
    }
}

/// Add scripts folder - scans for .zig files and adds them as "scripts/name" imports
pub fn addScriptsFolder(b: *Build, module: *Build.Module, folder_path: []const u8) void {
    addFolderImports(b, module, folder_path, "scripts");
}

/// Add components folder - scans for .zig files and adds them as "components/name" imports
pub fn addComponentsFolder(b: *Build, module: *Build.Module, folder_path: []const u8) void {
    addFolderImports(b, module, folder_path, "components");
}

/// Add prefabs folder - scans for .zig files and adds them as "prefabs/name" imports
pub fn addPrefabsFolder(b: *Build, module: *Build.Module, folder_path: []const u8) void {
    addFolderImports(b, module, folder_path, "prefabs");
}

/// Scan a folder and return a list of .zig file names (without extension)
/// Returns a slice of file names that can be used for registry generation
pub fn scanFolder(allocator: std.mem.Allocator, folder_path: []const u8) []const []const u8 {
    var names = std.ArrayList([]const u8).init(allocator);

    const dir = std.fs.cwd().openDir(folder_path, .{ .iterate = true }) catch return names.toOwnedSlice() catch &.{};
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const name = allocator.dupe(u8, entry.name[0 .. entry.name.len - 4]) catch continue;
            names.append(name) catch continue;
        }
    }

    return names.toOwnedSlice() catch &.{};
}

test "build_helpers module compiles" {
    _ = addFolderImports;
    _ = addScriptsFolder;
    _ = addComponentsFolder;
    _ = addPrefabsFolder;
    _ = scanFolder;
}
