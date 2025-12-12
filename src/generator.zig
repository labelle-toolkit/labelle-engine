// Project file generator for labelle-engine
//
// Generates build.zig, build.zig.zon, and main.zig based on:
// - project.labelle configuration
// - Folder contents (prefabs/, components/, scripts/, scenes/)
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
const zts = @import("zts");
const project_config = @import("project_config.zig");

const ProjectConfig = project_config.ProjectConfig;

// Embed templates at compile time
const build_zig_zon_tmpl = @embedFile("templates/build_zig_zon.txt");
const build_zig_tmpl = @embedFile("templates/build_zig.txt");
const main_raylib_tmpl = @embedFile("templates/main_raylib.txt");
const main_sokol_tmpl = @embedFile("templates/main_sokol.txt");

/// Sanitize a project name to be a valid Zig identifier
/// Replaces hyphens with underscores
fn sanitizeZigIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (c == '-') '_' else c;
    }
    return result;
}

/// Options for generating build.zig.zon
pub const BuildZonOptions = struct {
    /// Path to labelle-engine (for local development). If null, uses URL.
    engine_path: ?[]const u8 = null,
    /// Package fingerprint. If null, uses placeholder (0x0).
    fingerprint: ?u64 = null,
};

/// Generate build.zig.zon content
pub fn generateBuildZon(allocator: std.mem.Allocator, config: ProjectConfig, options: BuildZonOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Sanitize project name for Zig identifier (replace - with _)
    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
    defer allocator.free(zig_name);

    // Write header with fingerprint and sanitized name
    // Use provided fingerprint or placeholder (0x0) that will be replaced later
    const fingerprint = options.fingerprint orelse 0x0;
    try zts.print(build_zig_zon_tmpl, "header", .{ fingerprint, zig_name }, writer);

    // Write engine dependency (path or URL)
    if (options.engine_path) |path| {
        try zts.print(build_zig_zon_tmpl, "engine_path", .{path}, writer);
    } else {
        try zts.print(build_zig_zon_tmpl, "engine_url", .{}, writer);
    }
    try zts.print(build_zig_zon_tmpl, "engine_end", .{}, writer);

    // Write plugin dependencies
    for (config.plugins) |plugin| {
        // Use custom URL if provided, otherwise default to github.com/labelle-toolkit/{name}
        const plugin_url = plugin.url orelse blk: {
            const default_url = try std.fmt.allocPrint(allocator, "github.com/labelle-toolkit/{s}", .{plugin.name});
            break :blk default_url;
        };
        defer if (plugin.url == null) allocator.free(plugin_url);

        // Template args: name, url, version
        try zts.print(build_zig_zon_tmpl, "plugin", .{ plugin.name, plugin_url, plugin.version }, writer);
    }

    // Write closing
    try zts.print(build_zig_zon_tmpl, "deps_end", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate build.zig content
pub fn generateBuildZig(allocator: std.mem.Allocator, config: ProjectConfig) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Sanitize project name for Zig identifier (replace - with _)
    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
    defer allocator.free(zig_name);

    // Get the default backends from project config
    const default_backend = switch (config.backend) {
        .raylib => "raylib",
        .sokol => "sokol",
    };

    const default_ecs_backend = switch (config.ecs_backend) {
        .zig_ecs => "zig_ecs",
        .zflecs => "zflecs",
    };

    // Write common header (includes backend options)
    // Template args: graphics_backend (x2), ecs_backend (x2)
    try zts.print(build_zig_tmpl, "header", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend }, writer);

    // Write plugin dependency declarations
    // Sanitize plugin names for use as Zig identifiers
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }

    // Also track module names for imports
    var plugin_module_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (config.plugins, 0..) |plugin, i| {
            // Only free if we allocated (when plugin.module was null)
            if (plugin.module == null) allocator.free(plugin_module_names[i]);
        }
        allocator.free(plugin_module_names);
    }

    for (config.plugins, 0..) |plugin, i| {
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        plugin_zig_names[i] = plugin_zig_name;

        // Get module name - use explicit module if provided, otherwise default to sanitized name
        const plugin_module_name = plugin.module orelse blk: {
            const default_module = try sanitizeZigIdentifier(allocator, plugin.name);
            break :blk default_module;
        };
        plugin_module_names[i] = plugin_module_name;

        // Template args: zig_name, name, zig_name, zig_name, module_name
        try zts.print(build_zig_tmpl, "plugin_dep", .{ plugin_zig_name, plugin.name, plugin_zig_name, plugin_zig_name, plugin_module_name }, writer);
    }

    // Write backend-specific executable setup (start of imports)
    // Template args: project_name
    switch (config.backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib_exe_start", .{zig_name}, writer),
        .sokol => try zts.print(build_zig_tmpl, "sokol_exe_start", .{zig_name}, writer),
    }

    // Write plugin imports
    for (config.plugins, 0..) |plugin, i| {
        // Template args: name, zig_name
        try zts.print(build_zig_tmpl, "plugin_import", .{ plugin.name, plugin_zig_names[i] }, writer);
    }

    // Write backend-specific executable setup (end of imports)
    switch (config.backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib_exe_end", .{}, writer),
        .sokol => try zts.print(build_zig_tmpl, "sokol_exe_end", .{}, writer),
    }

    // Write common footer
    try zts.print(build_zig_tmpl, "footer", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Capitalize first letter of a string (returns stack-allocated buffer)
fn capitalize(name: []const u8) [64]u8 {
    if (name.len > 64) @panic("name is too long for capitalize buffer (max 64 chars)");
    var type_name: [64]u8 = undefined;
    @memcpy(type_name[0..name.len], name);
    if (name.len > 0 and type_name[0] >= 'a' and type_name[0] <= 'z') {
        type_name[0] -= ('a' - 'A');
    }
    return type_name;
}

/// Generate main.zig content based on folder contents (raylib backend)
fn generateMainZigRaylib(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Header with project name
    try zts.print(main_raylib_tmpl, "header", .{config.name}, writer);

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_raylib_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_raylib_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports (with capitalized type names)
    for (components) |name| {
        const type_name = capitalize(name);
        try zts.print(main_raylib_tmpl, "component_export", .{ type_name[0..name.len], name, type_name[0..name.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_raylib_tmpl, "script_import", .{ name, name }, writer);
    }

    // Main module reference
    try zts.print(main_raylib_tmpl, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_raylib_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_raylib_tmpl, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_raylib_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Component registry
    if (components.len == 0) {
        try zts.print(main_raylib_tmpl, "component_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_tmpl, "component_registry_start", .{}, writer);
        for (components) |name| {
            const type_name = capitalize(name);
            try zts.print(main_raylib_tmpl, "component_registry_item", .{ type_name[0..name.len], type_name[0..name.len] }, writer);
        }
        try zts.print(main_raylib_tmpl, "component_registry_end", .{}, writer);
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(main_raylib_tmpl, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_tmpl, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(main_raylib_tmpl, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_raylib_tmpl, "script_registry_end", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(main_raylib_tmpl, "loader", .{config.initial_scene}, writer);

    // Main function
    try zts.print(main_raylib_tmpl, "main_fn", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate main.zig content for sokol backend
fn generateMainZigSokol(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Header with project name
    try zts.print(main_sokol_tmpl, "header", .{config.name}, writer);

    // State struct
    try zts.print(main_sokol_tmpl, "state", .{}, writer);

    // Callbacks
    try zts.print(main_sokol_tmpl, "init_cb", .{}, writer);
    try zts.print(main_sokol_tmpl, "frame_cb", .{}, writer);
    try zts.print(main_sokol_tmpl, "cleanup_cb", .{}, writer);
    try zts.print(main_sokol_tmpl, "event_cb", .{}, writer);

    // Main function with window config
    try zts.print(main_sokol_tmpl, "main_fn", .{ config.window.width, config.window.height, config.window.title }, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate main.zig content based on folder contents
pub fn generateMainZig(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
) ![]const u8 {
    return switch (config.backend) {
        .raylib => generateMainZigRaylib(allocator, config, prefabs, components, scripts),
        .sokol => generateMainZigSokol(allocator, config),
    };
}

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

/// Options for project generation
pub const GenerateOptions = struct {
    /// Path to labelle-engine (for local development). If null, uses URL.
    engine_path: ?[]const u8 = null,
};

/// Generate all project files (build.zig, build.zig.zon, main.zig)
pub fn generateProject(allocator: std.mem.Allocator, project_path: []const u8, options: GenerateOptions) !void {
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

    // Generate build.zig and main.zig first
    const build_zig = try generateBuildZig(allocator, config);
    defer allocator.free(build_zig);

    const main_zig = try generateMainZig(allocator, config, prefabs, components, scripts);
    defer allocator.free(main_zig);

    // File paths
    const build_zig_zon_path = try std.fs.path.join(allocator, &.{ project_path, "build.zig.zon" });
    defer allocator.free(build_zig_zon_path);
    const build_zig_path = try std.fs.path.join(allocator, &.{ project_path, "build.zig" });
    defer allocator.free(build_zig_path);
    const main_zig_path = try std.fs.path.join(allocator, &.{ project_path, "main.zig" });
    defer allocator.free(main_zig_path);

    const cwd = std.fs.cwd();

    // Generate build.zig.zon with placeholder fingerprint first
    const initial_build_zig_zon = try generateBuildZon(allocator, config, .{
        .engine_path = options.engine_path,
        .fingerprint = null, // placeholder 0x0
    });
    defer allocator.free(initial_build_zig_zon);

    // Write all files
    try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = initial_build_zig_zon });
    try cwd.writeFile(.{ .sub_path = build_zig_path, .data = build_zig });
    try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });

    // Run zig build to get the correct fingerprint from the error message
    const fingerprint = try detectFingerprint(allocator, project_path);

    // Regenerate build.zig.zon with correct fingerprint
    const final_build_zig_zon = try generateBuildZon(allocator, config, .{
        .engine_path = options.engine_path,
        .fingerprint = fingerprint,
    });
    defer allocator.free(final_build_zig_zon);

    try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = final_build_zig_zon });
}

/// Run zig build and parse the suggested fingerprint from the error output
fn detectFingerprint(allocator: std.mem.Allocator, project_path: []const u8) !u64 {
    // Run zig build in the project directory
    var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    child.cwd = project_path;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    // Spawn the child process
    try child.spawn();

    // Collect output using ArrayLists
    var stdout_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stderr_buf.deinit(allocator);

    // Run and collect output (allocator, stdout_buf, stderr_buf, max_output_bytes)
    _ = child.collectOutput(allocator, &stdout_buf, &stderr_buf, 64 * 1024) catch {};
    const stderr_output = stderr_buf.items;

    // Parse fingerprint from error message like:
    // "missing top-level 'fingerprint' field; suggested value: 0xbc20e1ab89c1b519"
    // or "invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0xbc20e1ab89c1b519"
    const fingerprint = parseFingerprint(stderr_output) orelse {
        // If we can't parse it, return a default (this shouldn't happen)
        return error.FingerprintNotFound;
    };

    return fingerprint;
}

/// Parse fingerprint value from zig build error output
fn parseFingerprint(output: []const u8) ?u64 {
    // Look for "suggested value: 0x" or "use this value: 0x"
    const patterns = [_][]const u8{
        "suggested value: 0x",
        "use this value: 0x",
    };

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, output, pattern)) |start| {
            const hex_start = start + pattern.len;
            // Find end of hex number (until non-hex character)
            var hex_end = hex_start;
            while (hex_end < output.len) : (hex_end += 1) {
                const c = output[hex_end];
                if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                    break;
                }
            }
            if (hex_end > hex_start) {
                const hex_str = output[hex_start..hex_end];
                return std.fmt.parseInt(u64, hex_str, 16) catch null;
            }
        }
    }
    return null;
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

    // Generate main.zig
    const main_zig = try generateMainZig(allocator, config, prefabs, components, scripts);
    defer allocator.free(main_zig);

    // Write main.zig to project root
    const main_zig_path = try std.fs.path.join(allocator, &.{ project_path, "main.zig" });
    defer allocator.free(main_zig_path);

    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });
}
