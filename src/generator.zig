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
};

/// Generate build.zig.zon content
pub fn generateBuildZon(allocator: std.mem.Allocator, config: ProjectConfig, options: BuildZonOptions) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Sanitize project name for Zig identifier (replace - with _)
    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
    defer allocator.free(zig_name);

    // Generate a deterministic fingerprint based on project name
    var hash = std.hash.Fnv1a_64.init();
    hash.update(config.name);
    hash.update("labelle-game-v1");
    const fingerprint = hash.final();

    // Write header with fingerprint and sanitized name
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
        try zts.print(build_zig_zon_tmpl, "plugin", .{ plugin.name, plugin.name }, writer);
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

    // Write template with backend-specific section
    // Template args: graphics_backend (x2), ecs_backend (x2), project_name
    switch (config.backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend, zig_name }, writer),
        .sokol => try zts.print(build_zig_tmpl, "sokol", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend, zig_name }, writer),
    }

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

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_raylib_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_raylib_tmpl, "prefab_registry_item", .{name}, writer);
        }
        try zts.print(main_raylib_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Main module reference
    try zts.print(main_raylib_tmpl, "main_module", .{}, writer);

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
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - 4]);
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
    const prefabs = try scanFolder(allocator, prefabs_path);
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

    // Generate files
    const build_zig_zon = try generateBuildZon(allocator, config, .{
        .engine_path = options.engine_path,
    });
    defer allocator.free(build_zig_zon);

    const build_zig = try generateBuildZig(allocator, config);
    defer allocator.free(build_zig);

    const main_zig = try generateMainZig(allocator, config, prefabs, components, scripts);
    defer allocator.free(main_zig);

    // Write files to project root
    const build_zig_zon_path = try std.fs.path.join(allocator, &.{ project_path, "build.zig.zon" });
    defer allocator.free(build_zig_zon_path);
    const build_zig_path = try std.fs.path.join(allocator, &.{ project_path, "build.zig" });
    defer allocator.free(build_zig_path);
    const main_zig_path = try std.fs.path.join(allocator, &.{ project_path, "main.zig" });
    defer allocator.free(main_zig_path);

    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = build_zig_zon });
    try cwd.writeFile(.{ .sub_path = build_zig_path, .data = build_zig });
    try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });
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
    const prefabs = try scanFolder(allocator, prefabs_path);
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
