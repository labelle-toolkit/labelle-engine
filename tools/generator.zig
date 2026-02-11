// Project file generator for labelle-engine
//
// Generates build.zig, build.zig.zon, and main.zig based on:
// - project.labelle configuration
// - Folder contents (prefabs/, components/, scripts/, scenes/, hooks/)
//
// Usage:
//   const generator = @import("labelle-engine").generator;
//
//   // Generate all project files
//   try generator.generateProject(allocator, ".");
//
// Or via build step:
//   zig build generate

const std = @import("std");
const project_config = @import("project_config.zig");

const ProjectConfig = project_config.ProjectConfig;

// =============================================================================
// Submodule imports
// =============================================================================

const version_mod = @import("generator/version.zig");
const utils = @import("generator/utils.zig");
const build_files = @import("generator/build_files.zig");
const scanner_mod = @import("generator/scanner.zig");
const fingerprint_mod = @import("generator/fingerprint.zig");

// Target generators
const raylib_desktop = @import("generator/targets/raylib_desktop.zig");
const raylib_wasm = @import("generator/targets/raylib_wasm.zig");
const sokol_desktop = @import("generator/targets/sokol_desktop.zig");
const sokol_ios = @import("generator/targets/sokol_ios.zig");
const mobile = @import("generator/targets/mobile.zig");
const sdl = @import("generator/targets/sdl.zig");
const glfw = @import("generator/targets/glfw.zig");

// =============================================================================
// Private aliases (used by orchestration in this file)
// =============================================================================

const Version = version_mod.Version;
const readPluginCompatibility = version_mod.readPluginCompatibility;

const sanitizeZigIdentifier = utils.sanitizeZigIdentifier;

const generateBuildZon = build_files.generateBuildZon;
const generateBuildZig = build_files.generateBuildZig;

const scanFolder = scanner_mod.scanFolder;
const scanZonFolder = scanner_mod.scanZonFolder;
const TaskHookScanResult = scanner_mod.TaskHookScanResult;
const scanForTaskHooks = scanner_mod.scanForTaskHooks;

const detectFingerprint = fingerprint_mod.detectFingerprint;

// =============================================================================
// Templates (only used by orchestration in this file)
// =============================================================================

const wasm_shell_minimal_html = @embedFile("templates/wasm_shell.html");

// =============================================================================
// Orchestration
// =============================================================================

/// Options for project generation
pub const GenerateOptions = struct {
    /// Path to labelle-engine (for local development). If null, uses URL.
    engine_path: ?[]const u8 = null,
    /// Engine version for URL mode (e.g., "0.13.0"). If null, hashes won't be fetched.
    engine_version: ?[]const u8 = null,
    /// If true, fetch dependency hashes using zig fetch (slower but produces valid build.zig.zon).
    /// Only applies when engine_path is null (URL mode).
    fetch_hashes: bool = true,
};

/// Recursively copy a directory and all its contents
fn copyDirRecursive(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    const cwd = std.fs.cwd();

    // Open source directory
    var src_dir = try cwd.openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    // Create destination directory
    try cwd.makePath(dest_path);
    var dest_dir = try cwd.openDir(dest_path, .{});
    defer dest_dir.close();

    // Iterate through source directory
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_entry_path = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_entry_path);

        const dest_entry_path = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_entry_path);

        switch (entry.kind) {
            .file => {
                // Copy file
                try cwd.copyFile(src_entry_path, cwd, dest_entry_path, .{});
            },
            .directory => {
                // Recursively copy subdirectory
                try copyDirRecursive(allocator, src_entry_path, dest_entry_path);
            },
            else => {
                // Skip symlinks and other special files
            },
        }
    }
}

/// Generate all project files (build.zig, build.zig.zon, main.zig)
pub fn generateProject(allocator: std.mem.Allocator, project_path: []const u8, options: GenerateOptions) !void {
    // Load project config
    const labelle_path = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
    defer allocator.free(labelle_path);

    const config = try ProjectConfig.load(allocator, labelle_path);
    defer config.deinit(allocator);

    // Use engine_version from project.labelle if specified, otherwise use CLI's version
    const effective_engine_version = config.engine_version orelse options.engine_version;

    // Check plugin compatibility with engine version
    std.debug.print("Checking plugin compatibility...\n", .{});
    const engine_ver = Version.parse(effective_engine_version orelse "0.0.0") catch |err| blk: {
        std.debug.print("Warning: Could not parse engine version '{s}': {any}\n", .{ effective_engine_version orelse "unknown", err });
        break :blk Version{ .major = 0, .minor = 0, .patch = 0 };
    };

    for (config.plugins) |plugin| {
        // Only check path-based plugins (URL plugins are assumed compatible via their own version constraints)
        if (!plugin.isPathBased()) continue;

        const plugin_path = plugin.path.?;

        // Try to read compatibility metadata
        const compat = readPluginCompatibility(allocator, project_path, plugin_path) catch |err| {
            std.debug.print("Warning: Could not read plugin compatibility for '{s}': {any}\n", .{ plugin.name, err });
            continue;
        };

        if (compat) |comp| {
            var compatibility = comp;
            defer compatibility.deinit();

            const result = compatibility.checkCompatibility(engine_ver);

            switch (result) {
                .compatible => {
                    std.debug.print("  ✓ Plugin '{s}' compatible with engine {d}.{d}.{d}\n", .{ plugin.name, engine_ver.major, engine_ver.minor, engine_ver.patch });
                },
                .incompatible => {
                    std.debug.print("\n", .{});
                    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
                    std.debug.print("ERROR: Incompatible Plugin Version\n", .{});
                    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
                    std.debug.print("\n", .{});
                    std.debug.print("Plugin:  {s}\n", .{plugin.name});
                    std.debug.print("Requires: engine >= {d}.{d}.{d} and < {d}.{d}.{d}\n", .{ compatibility.min_version.major, compatibility.min_version.minor, compatibility.min_version.patch, compatibility.max_version.major, compatibility.max_version.minor, compatibility.max_version.patch });
                    std.debug.print("Project:  using engine {d}.{d}.{d}\n", .{ engine_ver.major, engine_ver.minor, engine_ver.patch });
                    std.debug.print("\n", .{});
                    std.debug.print("Reason: {s}\n", .{compatibility.reason});
                    std.debug.print("\n", .{});
                    std.debug.print("Solutions:\n", .{});
                    std.debug.print("  1. Update engine version in project.labelle to >= {d}.{d}.{d}\n", .{ compatibility.min_version.major, compatibility.min_version.minor, compatibility.min_version.patch });
                    std.debug.print("  2. Update plugin '{s}' to a version compatible with engine {d}.{d}.{d}\n", .{ plugin.name, engine_ver.major, engine_ver.minor, engine_ver.patch });
                    std.debug.print("\n", .{});
                    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
                    return error.IncompatiblePluginVersion;
                },
                .untested => {
                    std.debug.print("  ⚠ Warning: Plugin '{s}' untested with engine {d}.{d}.{d}\n", .{ plugin.name, engine_ver.major, engine_ver.minor, engine_ver.patch });
                    std.debug.print("    (tested up to {d}.{d}.{d}, may have issues)\n", .{ compatibility.max_version.major, compatibility.max_version.minor, compatibility.max_version.patch });
                },
            }
        } else {
            // No metadata file = assume compatible (for now)
            std.debug.print("  - Plugin '{s}' has no compatibility metadata\n", .{plugin.name});
        }
    }

    // Scan folders
    const prefabs_path = try std.fs.path.join(allocator, &.{ project_path, "prefabs" });
    defer allocator.free(prefabs_path);
    const prefabs = try scanZonFolder(allocator, prefabs_path);
    defer {
        for (prefabs) |p| allocator.free(p);
        allocator.free(prefabs);
    }

    const enums_path = try std.fs.path.join(allocator, &.{ project_path, "enums" });
    defer allocator.free(enums_path);
    const enums = try scanFolder(allocator, enums_path);
    defer {
        for (enums) |e| allocator.free(e);
        allocator.free(enums);
    }

    const components_path = try std.fs.path.join(allocator, &.{ project_path, "components" });
    defer allocator.free(components_path);
    const components = try scanFolder(allocator, components_path);
    defer {
        for (components) |c| allocator.free(c);
        allocator.free(components);
    }

    const scripts_path = try std.fs.path.join(allocator, &.{ project_path, "scripts" });
    defer allocator.free(scripts_path);
    const scripts = try scanFolder(allocator, scripts_path);
    defer {
        for (scripts) |s| allocator.free(s);
        allocator.free(scripts);
    }

    const hooks_path = try std.fs.path.join(allocator, &.{ project_path, "hooks" });
    defer allocator.free(hooks_path);
    const hooks = try scanFolder(allocator, hooks_path);
    defer {
        for (hooks) |h| allocator.free(h);
        allocator.free(hooks);
    }

    // Scan for task hooks in hook files
    var task_hooks = try scanForTaskHooks(allocator, hooks_path, hooks, config);
    defer task_hooks.deinit(allocator);

    // Create output directory path
    const output_dir_path = try std.fs.path.join(allocator, &.{ project_path, config.getOutputDir() });
    defer allocator.free(output_dir_path);

    // Ensure output directory exists
    const cwd = std.fs.cwd();
    cwd.makeDir(output_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Generate files for each target
    for (config.getTargets()) |target| {
        const target_name = target.getName();

        std.debug.print("Generating for target '{s}':\n", .{target_name});

        // Generate main.zig for this target
        const main_zig = try generateMainZigForTarget(allocator, target, config, prefabs, enums, components, scripts, hooks, task_hooks);
        defer allocator.free(main_zig);

        // Create subfolder for this target: .labelle/{target_name}/
        const target_dir_path = try std.fs.path.join(allocator, &.{ output_dir_path, target_name });
        defer allocator.free(target_dir_path);

        // Create target directory
        try cwd.makePath(target_dir_path);

        // File paths: build.zig, build.zig.zon, and main.zig all in target subfolder
        const main_zig_filename = "main.zig";
        const main_zig_path = try std.fs.path.join(allocator, &.{ target_dir_path, main_zig_filename });
        defer allocator.free(main_zig_path);

        // Generate build.zig for this target (pass main filename so it can reference the correct file)
        const build_zig = try generateBuildZig(allocator, config, target, main_zig_filename);
        defer allocator.free(build_zig);

        const build_zig_filename = "build.zig";
        const build_zig_path = try std.fs.path.join(allocator, &.{ target_dir_path, build_zig_filename });
        defer allocator.free(build_zig_path);

        const build_zig_zon_filename = "build.zig.zon";
        const build_zig_zon_path = try std.fs.path.join(allocator, &.{ target_dir_path, build_zig_zon_filename });
        defer allocator.free(build_zig_zon_path);

        // Adjust engine_path for subfolder structure
        // Zig build.zig.zon requires relative paths, so we compute the relative path
        // from the target directory to the engine path
        var adjusted_engine_path: ?[]const u8 = null;
        if (options.engine_path) |path| {
            if (std.fs.path.isAbsolute(path)) {
                // For absolute paths, compute relative path from target directory
                // Target dir is at: <project>/.labelle/<target>/
                // We need to get the absolute path of the target directory first
                const project_real_path = try std.fs.cwd().realpathAlloc(allocator, ".");
                defer allocator.free(project_real_path);
                const target_abs_path = try std.fs.path.join(allocator, &.{ project_real_path, target_dir_path });
                defer allocator.free(target_abs_path);
                // Compute relative path from target directory to engine path
                adjusted_engine_path = try std.fs.path.relative(allocator, target_abs_path, path);
            } else {
                // Relative paths need to be adjusted for the subfolder structure
                adjusted_engine_path = try std.fmt.allocPrint(allocator, "../../{s}", .{path});
            }
        }
        defer if (adjusted_engine_path) |p| allocator.free(p);

        // Generate build.zig.zon with placeholder fingerprint first
        const initial_build_zig_zon = try generateBuildZon(allocator, config, .{
            .engine_path = adjusted_engine_path,
            .engine_version = effective_engine_version,
            .fingerprint = null,
            .fetch_hashes = false,
        });
        defer allocator.free(initial_build_zig_zon);

        // Write all files for this target
        try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });
        try cwd.writeFile(.{ .sub_path = build_zig_path, .data = build_zig });
        try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = initial_build_zig_zon });

        // Copy project directories into target directory for self-contained builds
        // This allows imports without violating Zig's module path restrictions
        const dirs_to_copy = [_][]const u8{ "components", "scripts", "prefabs", "scenes", "resources", "hooks", "enums" };
        for (dirs_to_copy) |dir_name| {
            const src_dir_path = try std.fs.path.join(allocator, &.{ project_path, dir_name });
            defer allocator.free(src_dir_path);

            const dest_dir_path = try std.fs.path.join(allocator, &.{ target_dir_path, dir_name });
            defer allocator.free(dest_dir_path);

            // Copy directory if it exists (some might not exist in all projects)
            copyDirRecursive(allocator, src_dir_path, dest_dir_path) catch |err| {
                if (err == error.FileNotFound) continue;
                std.debug.print("Error: Failed to copy {s}: {}\n", .{ dir_name, err });
                return err;
            };
        }

        // Copy project.labelle into target directory as well
        const src_labelle_path = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
        defer allocator.free(src_labelle_path);

        const dest_labelle_path = try std.fs.path.join(allocator, &.{ target_dir_path, "project.labelle" });
        defer allocator.free(dest_labelle_path);

        try cwd.copyFile(src_labelle_path, cwd, dest_labelle_path, .{});

        // For WASM targets with minimal shell, copy the bundled shell.html
        if (target.getPlatform() == .wasm) {
            if (config.wasm.shell) |shell| {
                if (std.mem.eql(u8, shell, "minimal")) {
                    // Write the bundled minimal shell.html to the target directory
                    const shell_path = try std.fs.path.join(allocator, &.{ target_dir_path, "shell.html" });
                    defer allocator.free(shell_path);

                    // Replace {PROJECT_NAME} placeholder with actual project name
                    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
                    defer allocator.free(zig_name);

                    const final_content = try std.mem.replaceOwned(u8, allocator, wasm_shell_minimal_html, "{PROJECT_NAME}", zig_name);
                    defer allocator.free(final_content);

                    try cwd.writeFile(.{ .sub_path = shell_path, .data = final_content });
                }
            }
        }

        // Detect fingerprint by running zig build in the target directory
        std.debug.print("Fetching {s} fingerprint...\n", .{target_name});
        const detected_fingerprint = detectFingerprint(allocator, target_dir_path, build_zig_filename) catch |err| blk: {
            std.debug.print("Warning: Failed to detect fingerprint for {s}: {}\n", .{ target_name, err });
            std.debug.print("Using placeholder 0x0 (you may need to update manually)\n", .{});
            break :blk null;
        };

        // Generate final build.zig.zon with detected fingerprint
        const final_build_zig_zon = try generateBuildZon(allocator, config, .{
            .engine_path = adjusted_engine_path,
            .engine_version = effective_engine_version,
            .fingerprint = detected_fingerprint,
            .fetch_hashes = options.fetch_hashes,
        });
        defer allocator.free(final_build_zig_zon);

        try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = final_build_zig_zon });

        std.debug.print("  - {s}/{s}\n", .{ target_name, main_zig_filename });
        std.debug.print("  - {s}/{s}\n", .{ target_name, build_zig_filename });
        std.debug.print("  - {s}/{s}\n", .{ target_name, build_zig_zon_filename });

        // Verify the generated directory contains the expected files
        const expected_files = [_][]const u8{ main_zig_filename, build_zig_filename, build_zig_zon_filename };
        for (expected_files) |filename| {
            const file_path = try std.fs.path.join(allocator, &.{ target_dir_path, filename });
            defer allocator.free(file_path);

            cwd.access(file_path, .{}) catch |err| {
                std.debug.print("Error: Post-generation verification failed for {s}/{s}: {any}\n", .{ target_name, filename, err });
                return error.GenerationVerificationFailed;
            };
        }
    }
}

/// Generate main.zig content based on folder contents
pub fn generateMainZig(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    // For now, use the first target
    // TODO: This function will be replaced by per-target generation
    const first_target = config.getTargets()[0];
    return generateMainZigForTarget(allocator, first_target, config, prefabs, enums, components, scripts, hooks, task_hooks);
}

/// Generate main.zig for a specific target (new multi-target approach)
fn generateMainZigForTarget(
    allocator: std.mem.Allocator,
    target: project_config.Target,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    return switch (target) {
        .raylib_desktop => raylib_desktop.generateMainZigRaylib(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .raylib_wasm => raylib_wasm.generateMainZigRaylibWasm(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sokol_desktop => sokol_desktop.generateMainZigSokol(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sokol_wasm => mobile.generateMainZigWasm(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sokol_ios => sokol_ios.generateMainZigSokolIos(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sokol_android => mobile.generateMainZigSokolAndroid(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sdl_desktop => sdl.generateMainZigSdl(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .bgfx_desktop => glfw.generateMainZigBgfx(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .wgpu_native_desktop => glfw.generateMainZigWgpuNative(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
    };
}

/// Generate only main.zig (for use during build when build.zig already exists)
pub fn generateMainOnly(allocator: std.mem.Allocator, project_path: []const u8) !void {
    // Load project config
    const labelle_path = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
    defer allocator.free(labelle_path);

    const config = try ProjectConfig.load(allocator, labelle_path);
    defer config.deinit(allocator);

    // Scan folders
    const prefabs_path = try std.fs.path.join(allocator, &.{ project_path, "prefabs" });
    defer allocator.free(prefabs_path);
    const prefabs = try scanZonFolder(allocator, prefabs_path);
    defer {
        for (prefabs) |p| allocator.free(p);
        allocator.free(prefabs);
    }

    const enums_path = try std.fs.path.join(allocator, &.{ project_path, "enums" });
    defer allocator.free(enums_path);
    const enums = try scanFolder(allocator, enums_path);
    defer {
        for (enums) |e| allocator.free(e);
        allocator.free(enums);
    }

    const components_path = try std.fs.path.join(allocator, &.{ project_path, "components" });
    defer allocator.free(components_path);
    const components = try scanFolder(allocator, components_path);
    defer {
        for (components) |c| allocator.free(c);
        allocator.free(components);
    }

    const scripts_path = try std.fs.path.join(allocator, &.{ project_path, "scripts" });
    defer allocator.free(scripts_path);
    const scripts = try scanFolder(allocator, scripts_path);
    defer {
        for (scripts) |s| allocator.free(s);
        allocator.free(scripts);
    }

    const hooks_path = try std.fs.path.join(allocator, &.{ project_path, "hooks" });
    defer allocator.free(hooks_path);
    const hooks = try scanFolder(allocator, hooks_path);
    defer {
        for (hooks) |h| allocator.free(h);
        allocator.free(hooks);
    }

    // Scan for task hooks in hook files
    var task_hooks = try scanForTaskHooks(allocator, hooks_path, hooks, config);
    defer task_hooks.deinit(allocator);

    // Generate main.zig
    const main_zig = try generateMainZig(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks);
    defer allocator.free(main_zig);

    // Write main.zig to project root (needs project-relative imports)
    const main_zig_path = try std.fs.path.join(allocator, &.{ project_path, "main.zig" });
    defer allocator.free(main_zig_path);

    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });
}

/// Get the output directory path for a project
pub fn getOutputDir(allocator: std.mem.Allocator, project_path: []const u8) ![]const u8 {
    // Load project config to get output_dir
    const labelle_path = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
    defer allocator.free(labelle_path);

    const config = try ProjectConfig.load(allocator, labelle_path);
    // Must join path before freeing config, since output_dir points into config memory
    const result = try std.fs.path.join(allocator, &.{ project_path, config.getOutputDir() });
    config.deinit(allocator);

    return result;
}
