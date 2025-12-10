// Build helpers for labelle-engine projects
//
// This module provides build-time functions for:
// - Generating main.zig from project.labelle and folder contents
// - Scanning folders for scripts, components, and prefabs
//
// Example usage in build.zig:
//
//   const engine_dep = b.dependency("labelle-engine", .{ .target = target, .optimize = optimize });
//   const build_helpers = @import("labelle-engine").build_helpers;
//
//   // Add standard labelle game executable with auto-generated main.zig
//   const exe = build_helpers.addGame(b, engine_dep, .{});
//
//   const run_cmd = b.addRunArtifact(exe);
//   const run_step = b.step("run", "Run the game");
//   run_step.dependOn(&run_cmd.step);

const std = @import("std");
const Build = std.Build;
const generator = @import("generator.zig");

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
            const source_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ folder_path, entry.name }) catch {
                b.allocator.free(import_name);
                continue;
            };

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
            names.append(name) catch {
                allocator.free(name);
                continue;
            };
        }
    }

    return names.toOwnedSlice() catch {
        for (names.items) |n| allocator.free(n);
        names.deinit();
        return &.{};
    };
}

/// Configuration for addGame
pub const GameConfig = struct {
    /// Name of the executable (defaults to project name from project.labelle)
    name: ?[]const u8 = null,
    /// Path to project.labelle file
    project_file: []const u8 = "project.labelle",
};

/// Add a labelle game executable with auto-generated main.zig
/// This function:
/// 1. Runs the generator to create main.zig from project.labelle
/// 2. Sets up the executable with all necessary imports
/// 3. Returns the compile step for the executable
pub fn addGame(
    b: *Build,
    engine_dep: *Build.Dependency,
    config: GameConfig,
) *Build.Step.Compile {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the generator executable from the engine dependency
    const generator_exe = engine_dep.artifact("labelle-generate");

    // Run the generator to create main.zig
    const generate_step = b.addRunArtifact(generator_exe);
    generate_step.addArg("."); // Generate in current directory

    // Determine executable name
    const exe_name = config.name orelse blk: {
        // Try to read name from project.labelle at build time
        // Fall back to "game" if not available
        break :blk "game";
    };

    // Create the executable
    const engine_mod = engine_dep.module("labelle-engine");

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
            },
        }),
    });

    // Make compilation depend on generation
    exe.step.dependOn(&generate_step.step);

    b.installArtifact(exe);

    return exe;
}

