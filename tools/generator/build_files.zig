const std = @import("std");
const zts = @import("zts");
const project_config = @import("../project_config.zig");
const utils = @import("utils.zig");

const ProjectConfig = project_config.ProjectConfig;
const sanitizeZigIdentifier = utils.sanitizeZigIdentifier;
const fetchPackageHash = utils.fetchPackageHash;

// Embed templates at compile time
const build_zig_zon_tmpl = @embedFile("../templates/build_zig_zon.txt");
const build_zig_tmpl = @embedFile("../templates/build_zig.txt");
const build_raylib_wasm_tmpl = @embedFile("../templates/build/raylib_wasm_build.txt");

// =============================================================================
// Build File Generation
// =============================================================================

/// Options for generating build.zig.zon
pub const BuildZonOptions = struct {
    /// Path to labelle-engine (for local development). If null, uses URL.
    engine_path: ?[]const u8 = null,
    /// Package fingerprint. If null, uses placeholder (0x0).
    fingerprint: ?u64 = null,
    /// Engine version for URL mode (e.g., "0.13.0"). Required when engine_path is null.
    engine_version: ?[]const u8 = null,
    /// If true, fetch dependency hashes using zig fetch (slower but produces valid build.zig.zon).
    /// Only applies when engine_path is null (URL mode).
    fetch_hashes: bool = true,
};

/// Generate build.zig.zon content
pub fn generateBuildZon(allocator: std.mem.Allocator, config: ProjectConfig, options: BuildZonOptions) ![]const u8 {
    // For multi-target projects, we need to include dependencies for all backends used
    // Extract all unique backends from targets
    var backends: std.ArrayListUnmanaged(project_config.Backend) = .{};
    defer backends.deinit(allocator);

    var seen = std.AutoHashMap(project_config.Backend, void).init(allocator);
    defer seen.deinit();

    for (config.getTargets()) |target| {
        const backend = target.getBackend();
        if (!seen.contains(backend)) {
            try seen.put(backend, {});
            try backends.append(allocator, backend);
        }
    }

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
    } else if (options.fetch_hashes and options.engine_version != null) {
        // URL mode with hash fetching enabled
        const engine_version = options.engine_version.?;
        const engine_url = try std.fmt.allocPrint(allocator, "git+https://github.com/labelle-toolkit/labelle-engine#v{s}", .{engine_version});
        defer allocator.free(engine_url);

        std.debug.print("Fetching labelle-engine hash...\n", .{});
        if (try fetchPackageHash(allocator, engine_url)) |hash| {
            defer allocator.free(hash);
            try zts.print(build_zig_zon_tmpl, "engine_url", .{ engine_version, hash }, writer);
        } else {
            std.debug.print("Warning: Could not fetch engine hash, using placeholder\n", .{});
            try zts.print(build_zig_zon_tmpl, "engine_url_no_hash", .{}, writer);
        }
    } else {
        // Hashes disabled or no version provided
        try zts.print(build_zig_zon_tmpl, "engine_url_no_hash", .{}, writer);
    }
    try zts.print(build_zig_zon_tmpl, "engine_end", .{}, writer);

    // Write plugin dependencies
    for (config.plugins) |plugin| {
        // Check if this is a local path plugin
        if (plugin.isPathBased()) {
            // Adjust path for subfolder structure (.labelle/target/)
            // Plugin paths in project.labelle are relative to project root,
            // but generated files are in .labelle/target/, so add ../../
            const adjusted_plugin_path = try std.fmt.allocPrint(allocator, "../../{s}", .{plugin.path.?});
            defer allocator.free(adjusted_plugin_path);
            try zts.print(build_zig_zon_tmpl, "plugin_path", .{ plugin.name, adjusted_plugin_path }, writer);
            continue;
        }

        // Remote plugin: use custom URL if provided, otherwise default to github.com/labelle-toolkit/{name}
        var allocated_url = false;
        const plugin_url = plugin.url orelse blk: {
            allocated_url = true;
            const default_url = try std.fmt.allocPrint(allocator, "github.com/labelle-toolkit/{s}", .{plugin.name});
            break :blk default_url;
        };
        defer if (allocated_url) allocator.free(plugin_url);

        // Get the ref string (version/branch/commit)
        const ref = plugin.getRef();
        const is_version = plugin.isVersionRef();

        // Build URL: version uses #v{version}, branch/commit use #{ref}
        const full_url = if (is_version)
            try std.fmt.allocPrint(allocator, "git+https://{s}#v{s}", .{ plugin_url, ref })
        else
            try std.fmt.allocPrint(allocator, "git+https://{s}#{s}", .{ plugin_url, ref });
        defer allocator.free(full_url);

        // Try to fetch hash if enabled
        // Note: zts.print requires comptime section names, so we can't DRY this with variables
        if (options.fetch_hashes) {
            std.debug.print("Fetching {s} hash...\n", .{plugin.name});
            if (try fetchPackageHash(allocator, full_url)) |hash| {
                defer allocator.free(hash);
                if (is_version) {
                    try zts.print(build_zig_zon_tmpl, "plugin_version", .{ plugin.name, plugin_url, ref, hash }, writer);
                } else {
                    try zts.print(build_zig_zon_tmpl, "plugin_ref", .{ plugin.name, plugin_url, ref, hash }, writer);
                }
            } else {
                // Fetch failed, fall back to no-hash template
                std.debug.print("Warning: Could not fetch hash for {s}, using placeholder\n", .{plugin.name});
                if (is_version) {
                    try zts.print(build_zig_zon_tmpl, "plugin_version_no_hash", .{ plugin.name, plugin_url, ref }, writer);
                } else {
                    try zts.print(build_zig_zon_tmpl, "plugin_ref_no_hash", .{ plugin.name, plugin_url, ref }, writer);
                }
            }
        } else {
            // Hashes disabled
            if (is_version) {
                try zts.print(build_zig_zon_tmpl, "plugin_version_no_hash", .{ plugin.name, plugin_url, ref }, writer);
            } else {
                try zts.print(build_zig_zon_tmpl, "plugin_ref_no_hash", .{ plugin.name, plugin_url, ref }, writer);
            }
        }
    }

    // Write backend-specific dependencies (needed for @import in build.zig)
    var needs_raylib_zig = false;
    for (backends.items) |backend| {
        if (backend == .sdl) {
            try zts.print(build_zig_zon_tmpl, "sdl_dep", .{}, writer);
        }
        if (backend == .raylib) {
            // Check if any target with raylib is WASM
            for (config.getTargets()) |target| {
                if (target.getBackend() == .raylib and target.getPlatform() == .wasm) {
                    needs_raylib_zig = true;
                    break;
                }
            }
        }
    }

    // Add raylib_zig if needed for WASM builds
    if (needs_raylib_zig) {
        try zts.print(build_zig_zon_tmpl, "raylib_zig_dep", .{}, writer);
    }

    // Write closing
    try zts.print(build_zig_zon_tmpl, "deps_end", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate build.zig specifically for raylib WASM builds (uses specialized template)
fn generateBuildZigRaylibWasm(allocator: std.mem.Allocator, config: ProjectConfig, _: project_config.Target, main_filename: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Sanitize project name for Zig identifier (replace - with _)
    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
    defer allocator.free(zig_name);

    // Get the default backends from project config
    const default_backend = "raylib";
    const default_ecs_backend = switch (config.ecs_backend) {
        .zig_ecs => "zig_ecs",
        .zflecs => "zflecs",
    };
    const default_gui_backend = switch (config.gui_backend) {
        .none => "none",
        .raygui => "raygui",
        .microui => "microui",
        .nuklear => "nuklear",
        .imgui => "imgui",
    };
    const physics_enabled = config.physics.enabled;
    const physics_str = if (physics_enabled) "true" else "false";

    // With the new subfolder structure, main.zig is in the same directory as build.zig
    // So we can use the filename directly without any path prefix
    const main_file_rel_path = main_filename;

    // Write header
    try zts.print(build_raylib_wasm_tmpl, "header", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend, default_gui_backend, default_gui_backend, physics_str, physics_str }, writer);

    // Write plugin dependency declarations
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }

    var plugin_module_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.module == null) allocator.free(plugin_module_names[i]);
        }
        allocator.free(plugin_module_names);
    }

    for (config.plugins, 0..) |plugin, i| {
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        plugin_zig_names[i] = plugin_zig_name;

        const plugin_module_name = plugin.module orelse blk: {
            const default_module = try sanitizeZigIdentifier(allocator, plugin.name);
            break :blk default_module;
        };
        plugin_module_names[i] = plugin_module_name;

        // Use appropriate template based on plugin type:
        // - Path-based: use b.createModule() to avoid duplicate engine dependencies
        // - URL-based: use b.dependency() with only target/optimize (fixes #256)
        if (plugin.isPathBased()) {
            // Path-based plugin: create module manually
            // Adjust path for subfolder structure (.labelle/target/)
            // Plugin paths in project.labelle are relative to project root,
            // but generated files are in .labelle/target/, so add ../../
            const adjusted_plugin_path = try std.fmt.allocPrint(allocator, "../../{s}", .{plugin.path.?});
            defer allocator.free(adjusted_plugin_path);

            // Template args: zig_name, adjusted_path, zig_name, zig_name, module_name
            try zts.print(build_raylib_wasm_tmpl, "plugin_dep_path", .{ plugin_zig_name, adjusted_plugin_path, plugin_zig_name, plugin_zig_name, plugin_module_name }, writer);
        } else {
            // Remote plugin: get module from dependency
            // Template args: zig_name, plugin_name, zig_name, zig_name, module_name
            try zts.print(build_raylib_wasm_tmpl, "plugin_remote", .{ plugin_zig_name, plugin.name, plugin_zig_name, plugin_zig_name, plugin_module_name }, writer);
        }
    }

    // Write exe_mod setup
    try zts.print(build_raylib_wasm_tmpl, "exe_mod_start", .{main_file_rel_path}, writer);

    // Write plugin imports
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(build_raylib_wasm_tmpl, "plugin_import", .{ plugin.name, plugin_zig_names[i] }, writer);
    }

    // Write physics module import
    try zts.print(build_raylib_wasm_tmpl, "physics_import", .{}, writer);

    // Write native build start
    try zts.print(build_raylib_wasm_tmpl, "native_build_start", .{zig_name}, writer);

    // Close native block and start WASM block
    try zts.print(build_raylib_wasm_tmpl, "native_build_close_if", .{}, writer);

    // Write WASM build section
    try zts.print(build_raylib_wasm_tmpl, "wasm_build_start", .{zig_name}, writer);

    // Write shell configuration based on wasm.shell setting
    if (config.wasm.shell) |shell| {
        if (std.mem.eql(u8, shell, "minimal")) {
            // Use built-in minimal shell
            try zts.print(build_raylib_wasm_tmpl, "shell_minimal", .{}, writer);
        } else {
            // Use custom shell from project (path relative to project root)
            // Adjust path to be relative to the target directory
            try zts.print(build_raylib_wasm_tmpl, "shell_custom", .{shell}, writer);
        }
    } else {
        // Default: use raylib's shell
        try zts.print(build_raylib_wasm_tmpl, "shell_raylib", .{}, writer);
    }

    try zts.print(build_raylib_wasm_tmpl, "wasm_build_raylib", .{}, writer);
    try zts.print(build_raylib_wasm_tmpl, "wasm_emcc", .{zig_name}, writer);
    try zts.print(build_raylib_wasm_tmpl, "wasm_build_end", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate build.zig content
pub fn generateBuildZig(allocator: std.mem.Allocator, config: ProjectConfig, target_config: project_config.Target, main_filename: []const u8) ![]const u8 {
    // Use specialized template for raylib WASM builds
    const backend = target_config.getBackend();
    const platform = target_config.getPlatform();

    if (backend == .raylib and platform == .wasm) {
        return generateBuildZigRaylibWasm(allocator, config, target_config, main_filename);
    }

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Sanitize project name for Zig identifier (replace - with _)
    const zig_name = try sanitizeZigIdentifier(allocator, config.name);
    defer allocator.free(zig_name);

    // Use the provided target to determine backend and platform
    const target = target_config.getPlatform();
    _ = target_config.getName(); // target_name not needed for now

    // Get the default backends from project config
    const default_backend = switch (backend) {
        .raylib => "raylib",
        .sokol => "sokol",
        .sdl => "sdl",
        .bgfx => "bgfx",
        .wgpu_native => "wgpu_native",
    };

    const default_ecs_backend = switch (config.ecs_backend) {
        .zig_ecs => "zig_ecs",
        .zflecs => "zflecs",
    };

    const default_gui_backend = switch (config.gui_backend) {
        .none => "none",
        .raygui => "raygui",
        .microui => "microui",
        .nuklear => "nuklear",
        .imgui => "imgui",
    };

    const physics_enabled = config.physics.enabled;
    const physics_str = if (physics_enabled) "true" else "false";

    // With the new subfolder structure, main.zig is in the same directory as build.zig
    // So we can use the filename directly without any path prefix
    const main_file_rel_path = main_filename;

    // Write common header (includes backend options)
    // Template args: graphics_backend (x2), ecs_backend (x2), gui_backend (x2), physics (x2)
    try zts.print(build_zig_tmpl, "header", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend, default_gui_backend, default_gui_backend, physics_str, physics_str }, writer);

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

        // Use appropriate template based on plugin type:
        // - Path-based: use b.createModule() to avoid duplicate engine dependencies
        // - URL-based: use b.dependency() with only target/optimize (fixes #256)
        if (plugin.isPathBased()) {
            // Path-based plugin: create module manually
            // Adjust path for subfolder structure (.labelle/target/)
            // Plugin paths in project.labelle are relative to project root,
            // but generated files are in .labelle/target/, so add ../../
            const adjusted_plugin_path = try std.fmt.allocPrint(allocator, "../../{s}", .{plugin.path.?});
            defer allocator.free(adjusted_plugin_path);

            // Template args: zig_name, adjusted_path, zig_name, zig_name, module_name
            try zts.print(build_zig_tmpl, "plugin_dep_path", .{ plugin_zig_name, adjusted_plugin_path, plugin_zig_name, plugin_zig_name, plugin_module_name }, writer);
        } else {
            // Remote plugin: get module from dependency
            // Template args: zig_name, plugin_name, zig_name, zig_name, module_name
            try zts.print(build_zig_tmpl, "plugin_remote", .{ plugin_zig_name, plugin.name, plugin_zig_name, plugin_zig_name, plugin_module_name }, writer);
        }
    }

    // Write backend-specific executable setup (creates exe_mod and adds backend imports)
    switch (backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib_exe_start", .{main_file_rel_path}, writer),
        .sokol => {
            // iOS uses sokol through engine.sokol (no direct import to avoid module conflict)
            if (target == .ios) {
                try zts.print(build_zig_tmpl, "sokol_ios_exe_start", .{main_file_rel_path}, writer);
            } else {
                try zts.print(build_zig_tmpl, "sokol_exe_start", .{main_file_rel_path}, writer);
            }
        },
        .sdl => try zts.print(build_zig_tmpl, "sdl_exe_start", .{main_file_rel_path}, writer),
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_exe_start", .{main_file_rel_path}, writer),
        .wgpu_native => try zts.print(build_zig_tmpl, "wgpu_native_exe_start", .{main_file_rel_path}, writer),
    }

    // Write plugin imports (using exe_mod.addImport)
    for (config.plugins, 0..) |plugin, i| {
        // Template args: name, zig_name
        try zts.print(build_zig_tmpl, "plugin_import", .{ plugin.name, plugin_zig_names[i] }, writer);
    }

    // Write backend-specific executable setup end (empty section, just for ordering)
    switch (backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib_exe_end", .{}, writer),
        .sokol => {
            if (target == .ios) {
                try zts.print(build_zig_tmpl, "sokol_ios_exe_end", .{}, writer);
            } else {
                try zts.print(build_zig_tmpl, "sokol_exe_end", .{}, writer);
            }
        },
        .sdl => try zts.print(build_zig_tmpl, "sdl_exe_end", .{}, writer),
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_exe_end", .{}, writer),
        .wgpu_native => try zts.print(build_zig_tmpl, "wgpu_native_exe_end", .{}, writer),
    }

    // Write physics module import (conditional on physics_enabled)
    try zts.print(build_zig_tmpl, "physics_import", .{}, writer);

    // Write backend-specific executable creation (creates exe from exe_mod)
    // Template args: project_name
    switch (backend) {
        .raylib => try zts.print(build_zig_tmpl, "raylib_exe_final", .{zig_name}, writer),
        .sokol => try zts.print(build_zig_tmpl, "sokol_exe_final", .{zig_name}, writer),
        .sdl => try zts.print(build_zig_tmpl, "sdl_exe_final", .{zig_name}, writer),
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_exe_final", .{zig_name}, writer),
        .wgpu_native => try zts.print(build_zig_tmpl, "wgpu_native_exe_final", .{zig_name}, writer),
    }

    // Write backend-specific library linking (bgfx needs native libs)
    switch (backend) {
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_link", .{}, writer),
        else => {},
    }

    // Detect if this is a WASM target
    const is_wasm = target_config.getPlatform() == .wasm;

    // Always generate native path first (inside if (!is_wasm) runtime check)
    // iOS framework linking and standard footer
    try zts.print(build_zig_tmpl, "ios_frameworks", .{}, writer);
    try zts.print(build_zig_tmpl, "footer", .{}, writer);

    if (is_wasm) {
        // Close just the if block (not the build function) since we'll add else
        try zts.print(build_zig_tmpl, "native_build_close_if", .{}, writer);

        // WASM build path - use emsdk instead of native executable (inside else block)
        try zts.print(build_zig_tmpl, "wasm_build_start", .{zig_name}, writer);

        // Add backend-specific WASM linking
        switch (backend) {
            .raylib => try zts.print(build_zig_tmpl, "wasm_build_raylib", .{zig_name}, writer),
            // TODO: Add sokol WASM support when needed
            else => {},
        }

        // Close WASM block and build function
        try zts.print(build_zig_tmpl, "wasm_build_end", .{}, writer);
    } else {
        // Close native block and build function (no WASM path needed)
        try zts.print(build_zig_tmpl, "native_build_end", .{}, writer);
    }

    return buf.toOwnedSlice(allocator);
}
