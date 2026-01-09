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
const zts = @import("zts");
const project_config = @import("project_config.zig");

const ProjectConfig = project_config.ProjectConfig;

// Embed templates at compile time
const build_zig_zon_tmpl = @embedFile("templates/build_zig_zon.txt");
const build_zig_tmpl = @embedFile("templates/build_zig.txt");
const main_raylib_tmpl = @embedFile("templates/main_raylib.txt");
const main_sokol_tmpl = @embedFile("templates/main_sokol.txt");
const main_sdl_tmpl = @embedFile("templates/main_sdl.txt");
const main_bgfx_tmpl = @embedFile("templates/main_bgfx.txt");
const main_zgpu_tmpl = @embedFile("templates/main_zgpu.txt");

/// Sanitize a project name to be a valid Zig identifier
/// Replaces hyphens with underscores
fn sanitizeZigIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (c == '-') '_' else c;
    }
    return result;
}

/// Fetch package hash using zig fetch command
/// Returns the hash string or null if fetch fails
fn fetchPackageHash(allocator: std.mem.Allocator, url: []const u8) !?[]const u8 {
    // Run: zig fetch "<url>"
    var child = std.process.Child.init(&.{ "zig", "fetch", url }, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    // Collect output
    var stdout_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .{};
    defer stderr_buf.deinit(allocator);

    _ = child.collectOutput(allocator, &stdout_buf, &stderr_buf, 64 * 1024) catch {
        return null;
    };

    // Wait for process and check exit status
    const term = child.wait() catch {
        return null;
    };

    if (term.Exited != 0) {
        // Log stderr on failure for debugging
        if (stderr_buf.items.len > 0) {
            std.debug.print("zig fetch failed for '{s}':\n{s}\n", .{ url, stderr_buf.items });
        }
        return null;
    }

    // stdout contains the hash (trimmed)
    const stdout = std.mem.trim(u8, stdout_buf.items, &std.ascii.whitespace);
    if (stdout.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, stdout);
}

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
            try zts.print(build_zig_zon_tmpl, "plugin_path", .{ plugin.name, plugin.path.? }, writer);
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
    if (config.backend == .sdl) {
        try zts.print(build_zig_zon_tmpl, "sdl_dep", .{}, writer);
    }
    if (config.backend == .zgpu) {
        try zts.print(build_zig_zon_tmpl, "zgpu_dep", .{}, writer);
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
        .sdl => "sdl",
        .bgfx => "bgfx",
        .zgpu => "zgpu",
    };

    const default_ecs_backend = switch (config.ecs_backend) {
        .zig_ecs => "zig_ecs",
        .zflecs => "zflecs",
    };

    const physics_enabled = config.physics.enabled;
    const physics_str = if (physics_enabled) "true" else "false";

    // Write common header (includes backend options)
    // Template args: graphics_backend (x2), ecs_backend (x2), physics (x2)
    try zts.print(build_zig_tmpl, "header", .{ default_backend, default_backend, default_ecs_backend, default_ecs_backend, physics_str, physics_str }, writer);

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
        .sdl => try zts.print(build_zig_tmpl, "sdl_exe_start", .{zig_name}, writer),
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_exe_start", .{zig_name}, writer),
        .zgpu => try zts.print(build_zig_tmpl, "zgpu_exe_start", .{zig_name}, writer),
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
        .sdl => try zts.print(build_zig_tmpl, "sdl_exe_end", .{}, writer),
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_exe_end", .{}, writer),
        .zgpu => try zts.print(build_zig_tmpl, "zgpu_exe_end", .{}, writer),
    }

    // Write backend-specific library linking (bgfx/zgpu need native libs)
    switch (config.backend) {
        .bgfx => try zts.print(build_zig_tmpl, "bgfx_link", .{}, writer),
        .zgpu => try zts.print(build_zig_tmpl, "zgpu_link", .{}, writer),
        else => {},
    }

    // Write common footer
    try zts.print(build_zig_tmpl, "footer", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Result type for toPascalCase
const PascalCaseResult = struct { buf: [64]u8, len: usize };

/// Convert snake_case to PascalCase (returns stack-allocated buffer and length)
/// e.g., "task_workstation" -> "TaskWorkstation"
fn toPascalCase(name: []const u8) PascalCaseResult {
    if (name.len > 64) @panic("name is too long for toPascalCase buffer (max 64 chars)");
    var result: [64]u8 = undefined;
    var result_len: usize = 0;
    var capitalize_next = true;

    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            result[result_len] = if (capitalize_next) std.ascii.toUpper(c) else c;
            result_len += 1;
            capitalize_next = false;
        }
    }

    return .{ .buf = result, .len = result_len };
}

/// Generate main.zig content based on folder contents (raylib backend)
fn generateMainZigRaylib(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Check if any plugin contributes Components or has bindings
    var has_plugin_components = false;
    var has_plugin_bindings = false;
    for (config.plugins) |plugin| {
        if (plugin.components != null) {
            has_plugin_components = true;
        }
        if (plugin.hasBindings()) {
            has_plugin_bindings = true;
        }
    }

    // Pre-compute sanitized plugin names for Zig identifiers
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }
    for (config.plugins, 0..) |plugin, i| {
        plugin_zig_names[i] = try sanitizeZigIdentifier(allocator, plugin.name);
    }

    // Pre-compute PascalCase names for enums
    var enum_pascal_names = try allocator.alloc(PascalCaseResult, enums.len);
    defer allocator.free(enum_pascal_names);
    for (enums, 0..) |name, i| {
        enum_pascal_names[i] = toPascalCase(name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = toPascalCase(name);
    }

    // Header with project name
    try zts.print(main_raylib_tmpl, "header", .{config.name}, writer);

    // Plugin imports (using sanitized identifier and original name for import path)
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(main_raylib_tmpl, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Enum imports
    for (enums) |name| {
        try zts.print(main_raylib_tmpl, "enum_import", .{ name, name }, writer);
    }

    // Enum exports (with PascalCase type names)
    for (enums, 0..) |name, i| {
        const pascal = enum_pascal_names[i];
        try zts.print(main_raylib_tmpl, "enum_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // GameId type export (based on project.game_id)
    const game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    try zts.print(main_raylib_tmpl, "game_id_export", .{game_id_str}, writer);

    // Plugin bind declarations (generates consts like: const labelle_tasksBindItems = labelle_tasks.bind(Items);)
    for (config.plugins, 0..) |plugin, i| {
        for (plugin.bind) |bind_decl| {
            try zts.print(main_raylib_tmpl, "plugin_bind", .{ plugin_zig_names[i], bind_decl.arg, plugin_zig_names[i], bind_decl.func, bind_decl.arg }, writer);
        }
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_raylib_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_raylib_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports (with PascalCase type names)
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(main_raylib_tmpl, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_raylib_tmpl, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(main_raylib_tmpl, "hook_import", .{ name, name }, writer);
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

    // Component registry - determine which registry type to use
    // Check if any bind declaration has expanded components
    var has_expanded_bind_components = false;
    for (config.plugins) |plugin| {
        for (plugin.bind) |bind_decl| {
            if (bind_decl.components.len > 0) {
                has_expanded_bind_components = true;
                break;
            }
        }
        if (has_expanded_bind_components) break;
    }

    // Use ComponentRegistryMulti only when plugins contribute their own Components type
    // When we only have bind components (expanded in struct), use simple ComponentRegistry
    if (has_plugin_components) {
        // Use ComponentRegistryMulti to merge base components with plugin Components
        if (components.len == 0 and !has_expanded_bind_components) {
            try zts.print(main_raylib_tmpl, "component_registry_multi_empty_start", .{}, writer);
        } else {
            try zts.print(main_raylib_tmpl, "component_registry_multi_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_raylib_tmpl, "component_registry_multi_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }

            // Add bind component declarations INSIDE the struct
            for (config.plugins, 0..) |plugin, i| {
                for (plugin.bind) |bind_decl| {
                    if (bind_decl.components.len > 0) {
                        var comp_iter = std.mem.splitSequence(u8, bind_decl.components, ",");
                        while (comp_iter.next()) |comp_name| {
                            const trimmed = std.mem.trim(u8, comp_name, " ");
                            if (trimmed.len > 0) {
                                try zts.print(main_raylib_tmpl, "bind_component_item", .{ trimmed, plugin_zig_names[i], bind_decl.arg, trimmed }, writer);
                            }
                        }
                    }
                }
            }

            try zts.print(main_raylib_tmpl, "component_registry_multi_base_end", .{}, writer);
        }

        // Add plugin Components
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.components) |components_expr| {
                try zts.print(main_raylib_tmpl, "component_registry_multi_plugin", .{ plugin_zig_names[i], components_expr }, writer);
            }
        }
        // Add bind types as tuple elements only if no components specified
        for (config.plugins, 0..) |plugin, i| {
            for (plugin.bind) |bind_decl| {
                if (bind_decl.components.len == 0) {
                    try zts.print(main_raylib_tmpl, "component_registry_multi_bind", .{ plugin_zig_names[i], bind_decl.arg }, writer);
                }
            }
        }
        try zts.print(main_raylib_tmpl, "component_registry_multi_end", .{}, writer);
    } else if (has_expanded_bind_components) {
        // Only bind components - use simple ComponentRegistry (avoids comptime issues)
        try zts.print(main_raylib_tmpl, "component_registry_start", .{}, writer);
        for (component_pascal_names) |pascal| {
            try zts.print(main_raylib_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
        }
        // Add bind component declarations
        for (config.plugins, 0..) |plugin, i| {
            for (plugin.bind) |bind_decl| {
                if (bind_decl.components.len > 0) {
                    var comp_iter = std.mem.splitSequence(u8, bind_decl.components, ",");
                    while (comp_iter.next()) |comp_name| {
                        const trimmed = std.mem.trim(u8, comp_name, " ");
                        if (trimmed.len > 0) {
                            try zts.print(main_raylib_tmpl, "component_registry_bind_item", .{ trimmed, plugin_zig_names[i], bind_decl.arg, trimmed }, writer);
                        }
                    }
                }
            }
        }
        try zts.print(main_raylib_tmpl, "component_registry_end", .{}, writer);
    } else {
        // No plugins - use simple ComponentRegistry
        if (components.len == 0) {
            try zts.print(main_raylib_tmpl, "component_registry_empty", .{}, writer);
        } else {
            try zts.print(main_raylib_tmpl, "component_registry_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_raylib_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(main_raylib_tmpl, "component_registry_end", .{}, writer);
        }
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

    // Plugin engine hooks (for plugins with engine_hooks config)
    // This generates createEngineHooks calls and exports Context, MovementAction, PendingMovement
    var plugin_engine_hooks_count: usize = 0;
    var hook_files_used_by_plugins = std.StringHashMap(void).init(allocator);
    defer hook_files_used_by_plugins.deinit();

    for (config.plugins, 0..) |plugin, i| {
        if (plugin.engine_hooks) |eh| {
            plugin_engine_hooks_count += 1;

            // Parse the task_hooks reference to get hook file and struct name
            // Format: "hook_file.StructName" e.g., "task_hooks.GameHooks"
            var it = std.mem.splitScalar(u8, eh.task_hooks, '.');
            const hook_file = it.next() orelse continue;
            const struct_name = it.next() orelse "GameHooks";

            // Mark this hook file as used by a plugin (won't be included directly in MergeEngineHooks)
            hook_files_used_by_plugins.put(hook_file, {}) catch {};

            // Get item type: use explicit item_arg if specified, otherwise first bind arg
            const item_type = eh.item_arg orelse (if (plugin.bind.len > 0) plugin.bind[0].arg else "void");

            // Generate: const plugin_engine_hooks = plugin.createEngineHooks(GameId, ItemType, hook_file.GameHooks);
            // Template args: plugin_zig_name, plugin_zig_name, create_fn, item_type, hook_file, struct_name
            //                plugin_zig_name (for Context export prefix), plugin_zig_name
            try zts.print(main_raylib_tmpl, "plugin_engine_hooks", .{
                plugin_zig_names[i], // for const name
                plugin_zig_names[i], // for plugin module
                eh.create,           // createEngineHooks
                item_type,           // Items
                hook_file,           // task_hooks
                struct_name,         // GameHooks
                plugin_zig_names[i], // Context prefix
                plugin_zig_names[i], // Context value
            }, writer);
        }
    }

    // Hooks (merged engine hooks and Game type)
    // Filter out hook files that are only used by plugins (they only have GameHooks, not engine hooks)
    var filtered_hooks: std.ArrayListUnmanaged([]const u8) = .{};
    defer filtered_hooks.deinit(allocator);

    for (hooks) |name| {
        if (!hook_files_used_by_plugins.contains(name)) {
            try filtered_hooks.append(allocator, name);
        }
    }

    const has_any_hooks = filtered_hooks.items.len > 0 or plugin_engine_hooks_count > 0;

    if (!has_any_hooks) {
        try zts.print(main_raylib_tmpl, "hooks_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_tmpl, "hooks_start", .{}, writer);

        // Include hook files that have engine hooks
        for (filtered_hooks.items) |name| {
            try zts.print(main_raylib_tmpl, "hooks_item", .{name}, writer);
        }

        // Include plugin engine hooks
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.hasEngineHooks()) {
                try zts.print(main_raylib_tmpl, "hooks_plugin_item", .{plugin_zig_names[i]}, writer);
            }
        }

        try zts.print(main_raylib_tmpl, "hooks_end", .{}, writer);
    }

    // Task engine (legacy support - kept for backward compatibility)
    // This is only generated if no plugin has engine_hooks but task hooks are detected
    if (plugin_engine_hooks_count == 0 and task_hooks.has_task_hooks and task_hooks.tasks_plugin != null) {
        const plugin = task_hooks.tasks_plugin.?;

        // Get plugin zig name
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        defer allocator.free(plugin_zig_name);

        // Get type parameters (required for TaskEngine)
        const id_type = game_id_str;
        const item_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        // Generate TaskEngine type
        try zts.print(main_raylib_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, item_type }, writer);

        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_raylib_tmpl, "task_engine_hook_item", .{name}, writer);
        }

        try zts.print(main_raylib_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, item_type, plugin_zig_name, id_type, item_type }, writer);
    } else {
        try zts.print(main_raylib_tmpl, "task_engine_empty", .{}, writer);
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
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    // Sokol backend uses same logic as raylib - delegate to avoid duplication
    // For now, sokol templates don't have enum/bind sections, so skip them
    _ = enums;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Check if any plugin contributes Components
    var has_plugin_components = false;
    for (config.plugins) |plugin| {
        if (plugin.components != null) {
            has_plugin_components = true;
            break;
        }
    }

    // Pre-compute sanitized plugin names for Zig identifiers
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }
    for (config.plugins, 0..) |plugin, i| {
        plugin_zig_names[i] = try sanitizeZigIdentifier(allocator, plugin.name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = toPascalCase(name);
    }

    // Header with project name
    try zts.print(main_sokol_tmpl, "header", .{config.name}, writer);

    // Plugin imports (using sanitized identifier and original name for import path)
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(main_sokol_tmpl, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_sokol_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_sokol_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports (with PascalCase type names)
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(main_sokol_tmpl, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_sokol_tmpl, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(main_sokol_tmpl, "hook_import", .{ name, name }, writer);
    }

    // Main module reference
    try zts.print(main_sokol_tmpl, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_sokol_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_sokol_tmpl, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sokol_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Component registry - use ComponentRegistryMulti when plugins contribute Components
    if (has_plugin_components) {
        // Use ComponentRegistryMulti to merge base components with plugin components
        if (components.len == 0) {
            try zts.print(main_sokol_tmpl, "component_registry_multi_empty_start", .{}, writer);
        } else {
            try zts.print(main_sokol_tmpl, "component_registry_multi_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_sokol_tmpl, "component_registry_multi_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(main_sokol_tmpl, "component_registry_multi_base_end", .{}, writer);
        }
        // Add plugin Components (only for plugins that specify a components field)
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.components) |components_expr| {
                try zts.print(main_sokol_tmpl, "component_registry_multi_plugin", .{ plugin_zig_names[i], components_expr }, writer);
            }
        }
        try zts.print(main_sokol_tmpl, "component_registry_multi_end", .{}, writer);
    } else {
        // No plugins - use simple ComponentRegistry
        if (components.len == 0) {
            try zts.print(main_sokol_tmpl, "component_registry_empty", .{}, writer);
        } else {
            try zts.print(main_sokol_tmpl, "component_registry_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_sokol_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(main_sokol_tmpl, "component_registry_end", .{}, writer);
        }
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(main_sokol_tmpl, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_tmpl, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(main_sokol_tmpl, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sokol_tmpl, "script_registry_end", .{}, writer);
    }

    // Hooks (merged engine hooks and Game type)
    if (hooks.len == 0) {
        try zts.print(main_sokol_tmpl, "hooks_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_tmpl, "hooks_start", .{}, writer);
        for (hooks) |name| {
            try zts.print(main_sokol_tmpl, "hooks_item", .{name}, writer);
        }
        try zts.print(main_sokol_tmpl, "hooks_end", .{}, writer);
    }

    // Task engine with auto-wired hooks (if task hooks detected and labelle-tasks plugin configured)
    // Note: This is legacy support - prefer using engine_hooks config on plugins
    const sokol_game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    if (task_hooks.has_task_hooks and task_hooks.tasks_plugin != null) {
        const plugin = task_hooks.tasks_plugin.?;

        // Get plugin zig name
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        defer allocator.free(plugin_zig_name);

        // Get type parameters (required for TaskEngine)
        const id_type = sokol_game_id_str;
        const item_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        // Generate TaskEngine type
        try zts.print(main_sokol_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, item_type }, writer);

        // Add hook files that contain task hooks
        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_sokol_tmpl, "task_engine_hook_item", .{name}, writer);
        }

        try zts.print(main_sokol_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, item_type, plugin_zig_name, id_type, item_type }, writer);
    } else {
        try zts.print(main_sokol_tmpl, "task_engine_empty", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(main_sokol_tmpl, "loader", .{config.initial_scene}, writer);

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

/// Generate main.zig content for SDL backend
fn generateMainZigSdl(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    // SDL backend - for now, skip enum/bind sections (templates not updated yet)
    _ = enums;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Check if any plugin contributes Components
    var has_plugin_components = false;
    for (config.plugins) |plugin| {
        if (plugin.components != null) {
            has_plugin_components = true;
            break;
        }
    }

    // Pre-compute sanitized plugin names for Zig identifiers
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }
    for (config.plugins, 0..) |plugin, i| {
        plugin_zig_names[i] = try sanitizeZigIdentifier(allocator, plugin.name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = toPascalCase(name);
    }

    // Header with project name
    try zts.print(main_sdl_tmpl, "header", .{config.name}, writer);

    // Plugin imports (using sanitized identifier and original name for import path)
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(main_sdl_tmpl, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_sdl_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_sdl_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports (with PascalCase type names)
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(main_sdl_tmpl, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_sdl_tmpl, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(main_sdl_tmpl, "hook_import", .{ name, name }, writer);
    }

    // Main module reference
    try zts.print(main_sdl_tmpl, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_sdl_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sdl_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_sdl_tmpl, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sdl_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Component registry - use ComponentRegistryMulti when plugins contribute Components
    if (has_plugin_components) {
        if (components.len == 0) {
            try zts.print(main_sdl_tmpl, "component_registry_multi_empty_start", .{}, writer);
        } else {
            try zts.print(main_sdl_tmpl, "component_registry_multi_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_sdl_tmpl, "component_registry_multi_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(main_sdl_tmpl, "component_registry_multi_base_end", .{}, writer);
        }
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.components) |components_expr| {
                try zts.print(main_sdl_tmpl, "component_registry_multi_plugin", .{ plugin_zig_names[i], components_expr }, writer);
            }
        }
        try zts.print(main_sdl_tmpl, "component_registry_multi_end", .{}, writer);
    } else {
        if (components.len == 0) {
            try zts.print(main_sdl_tmpl, "component_registry_empty", .{}, writer);
        } else {
            try zts.print(main_sdl_tmpl, "component_registry_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_sdl_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(main_sdl_tmpl, "component_registry_end", .{}, writer);
        }
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(main_sdl_tmpl, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sdl_tmpl, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(main_sdl_tmpl, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sdl_tmpl, "script_registry_end", .{}, writer);
    }

    // Hooks (merged engine hooks and Game type)
    if (hooks.len == 0) {
        try zts.print(main_sdl_tmpl, "hooks_empty", .{}, writer);
    } else {
        try zts.print(main_sdl_tmpl, "hooks_start", .{}, writer);
        for (hooks) |name| {
            try zts.print(main_sdl_tmpl, "hooks_item", .{name}, writer);
        }
        try zts.print(main_sdl_tmpl, "hooks_end", .{}, writer);
    }

    // Task engine with auto-wired hooks (if task hooks detected and labelle-tasks plugin configured)
    // Note: This is legacy support - prefer using engine_hooks config on plugins
    const sdl_game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    if (task_hooks.has_task_hooks and task_hooks.tasks_plugin != null) {
        const plugin = task_hooks.tasks_plugin.?;

        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        defer allocator.free(plugin_zig_name);

        const id_type = sdl_game_id_str;
        const item_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        try zts.print(main_sdl_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, item_type }, writer);

        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_sdl_tmpl, "task_engine_hook_item", .{name}, writer);
        }

        try zts.print(main_sdl_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, item_type, plugin_zig_name, id_type, item_type }, writer);
    } else {
        try zts.print(main_sdl_tmpl, "task_engine_empty", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(main_sdl_tmpl, "loader", .{config.initial_scene}, writer);

    // Main function
    try zts.print(main_sdl_tmpl, "main_fn", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generic main.zig generator for GLFW-based backends (bgfx, zgpu)
/// Reduces code duplication by parameterizing the template and optional sections.
fn generateMainZigGlfw(
    comptime template: []const u8,
    comptime include_native_helpers: bool,
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Check if any plugin contributes Components or has bindings
    var has_plugin_components = false;
    var has_plugin_bindings = false;
    for (config.plugins) |plugin| {
        if (plugin.components != null) {
            has_plugin_components = true;
        }
        if (plugin.hasBindings()) {
            has_plugin_bindings = true;
        }
    }

    // Pre-compute sanitized plugin names for Zig identifiers
    var plugin_zig_names = try allocator.alloc([]const u8, config.plugins.len);
    defer {
        for (plugin_zig_names) |name| allocator.free(name);
        allocator.free(plugin_zig_names);
    }
    for (config.plugins, 0..) |plugin, i| {
        plugin_zig_names[i] = try sanitizeZigIdentifier(allocator, plugin.name);
    }

    // Pre-compute PascalCase names for enums
    var enum_pascal_names = try allocator.alloc(PascalCaseResult, enums.len);
    defer allocator.free(enum_pascal_names);
    for (enums, 0..) |name, i| {
        enum_pascal_names[i] = toPascalCase(name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = toPascalCase(name);
    }

    // Header with project name
    try zts.print(template, "header", .{config.name}, writer);

    // Plugin imports
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(template, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Enum imports
    for (enums) |name| {
        try zts.print(template, "enum_import", .{ name, name }, writer);
    }

    // Enum exports (with PascalCase type names)
    for (enums, 0..) |name, i| {
        const pascal = enum_pascal_names[i];
        try zts.print(template, "enum_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Plugin bind declarations (generates consts like: const labelle_tasksBindItems = labelle_tasks.bind(Items);)
    for (config.plugins, 0..) |plugin, i| {
        for (plugin.bind) |bind_decl| {
            try zts.print(template, "plugin_bind", .{ plugin_zig_names[i], bind_decl.arg, plugin_zig_names[i], bind_decl.func, bind_decl.arg }, writer);
        }
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(template, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(template, "component_import", .{ name, name }, writer);
    }

    // Component exports
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(template, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(template, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(template, "hook_import", .{ name, name }, writer);
    }

    // Main module reference
    try zts.print(template, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(template, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(template, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(template, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(template, "prefab_registry_end", .{}, writer);
    }

    // Component registry - use ComponentRegistryMulti when plugins contribute Components or bindings
    if (has_plugin_components or has_plugin_bindings) {
        // Check if any bind declaration has expanded components (to avoid using empty_start)
        var has_expanded_bind_components = false;
        for (config.plugins) |plugin| {
            for (plugin.bind) |bind_decl| {
                if (bind_decl.components.len > 0) {
                    has_expanded_bind_components = true;
                    break;
                }
            }
            if (has_expanded_bind_components) break;
        }

        // Use ComponentRegistryMulti to merge base components with plugin components
        if (components.len == 0 and !has_expanded_bind_components) {
            // Empty start template already includes closing brace
            try zts.print(template, "component_registry_multi_empty_start", .{}, writer);
        } else {
            try zts.print(template, "component_registry_multi_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(template, "component_registry_multi_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }

            // Add bind component declarations INSIDE the struct (if components are specified)
            for (config.plugins, 0..) |plugin, i| {
                for (plugin.bind) |bind_decl| {
                    if (bind_decl.components.len > 0) {
                        // Split comma-separated component names and generate declarations
                        var comp_iter = std.mem.splitSequence(u8, bind_decl.components, ",");
                        while (comp_iter.next()) |comp_name| {
                            const trimmed = std.mem.trim(u8, comp_name, " ");
                            if (trimmed.len > 0) {
                                // bind_component_item: comp_name, plugin_zig_name, bind_arg, comp_name
                                try zts.print(template, "bind_component_item", .{ trimmed, plugin_zig_names[i], bind_decl.arg, trimmed }, writer);
                            }
                        }
                    }
                }
            }

            // Close the base struct
            try zts.print(template, "component_registry_multi_base_end", .{}, writer);
        }

        // Add plugin Components (only for plugins that specify a components field)
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.components) |components_expr| {
                try zts.print(template, "component_registry_multi_plugin", .{ plugin_zig_names[i], components_expr }, writer);
            }
        }
        // Add plugin bind types as tuple elements ONLY if no components specified
        // (otherwise they were expanded inside the struct)
        for (config.plugins, 0..) |plugin, i| {
            for (plugin.bind) |bind_decl| {
                if (bind_decl.components.len == 0) {
                    try zts.print(template, "component_registry_multi_bind", .{ plugin_zig_names[i], bind_decl.arg }, writer);
                }
            }
        }
        try zts.print(template, "component_registry_multi_end", .{}, writer);
    } else {
        if (components.len == 0) {
            try zts.print(template, "component_registry_empty", .{}, writer);
        } else {
            try zts.print(template, "component_registry_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(template, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            try zts.print(template, "component_registry_end", .{}, writer);
        }
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(template, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(template, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(template, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(template, "script_registry_end", .{}, writer);
    }

    // Hooks
    if (hooks.len == 0) {
        try zts.print(template, "hooks_empty", .{}, writer);
    } else {
        try zts.print(template, "hooks_start", .{}, writer);
        for (hooks) |name| {
            try zts.print(template, "hooks_item", .{name}, writer);
        }
        try zts.print(template, "hooks_end", .{}, writer);
    }

    // Task engine
    // Note: This is legacy support - prefer using engine_hooks config on plugins
    const glfw_game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    if (task_hooks.has_task_hooks and task_hooks.tasks_plugin != null) {
        const plugin = task_hooks.tasks_plugin.?;
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        defer allocator.free(plugin_zig_name);
        const id_type = glfw_game_id_str;
        const item_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        try zts.print(template, "task_engine_start", .{ plugin_zig_name, id_type, item_type }, writer);
        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(template, "task_engine_hook_item", .{name}, writer);
        }
        try zts.print(template, "task_engine_end", .{ plugin_zig_name, id_type, item_type, plugin_zig_name, id_type, item_type }, writer);
    } else {
        try zts.print(template, "task_engine_empty", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(template, "loader", .{config.initial_scene}, writer);

    // Native helpers (only for bgfx backend)
    if (include_native_helpers) {
        try zts.print(template, "native_helpers", .{}, writer);
    }

    // Main function
    try zts.print(template, "main_fn", .{}, writer);

    return buf.toOwnedSlice(allocator);
}

/// Generate main.zig content for bgfx backend
fn generateMainZigBgfx(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    return generateMainZigGlfw(main_bgfx_tmpl, true, allocator, config, prefabs, enums, components, scripts, hooks, task_hooks);
}

/// Generate main.zig content for zgpu backend
fn generateMainZigZgpu(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    return generateMainZigGlfw(main_zgpu_tmpl, false, allocator, config, prefabs, enums, components, scripts, hooks, task_hooks);
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
    return switch (config.backend) {
        .raylib => generateMainZigRaylib(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sokol => generateMainZigSokol(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .sdl => generateMainZigSdl(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .bgfx => generateMainZigBgfx(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
        .zgpu => generateMainZigZgpu(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks),
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

/// Known task hook function names that trigger TaskEngine generation
const task_hook_names = [_][]const u8{
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
    config: ProjectConfig,
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
    for (task_hook_names) |hook_name| {
        const pattern = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{hook_name});
        defer allocator.free(pattern);

        if (std.mem.indexOf(u8, content[0..bytes_read], pattern) != null) {
            return true;
        }
    }

    return false;
}

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

/// Generate all project files (build.zig, build.zig.zon, main.zig)
pub fn generateProject(allocator: std.mem.Allocator, project_path: []const u8, options: GenerateOptions) !void {
    // Load project config
    const labelle_path = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
    defer allocator.free(labelle_path);

    const config = try ProjectConfig.load(allocator, labelle_path);
    defer config.deinit(allocator);

    // Use engine_version from project.labelle if specified, otherwise use CLI's version
    const effective_engine_version = config.engine_version orelse options.engine_version;

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

    // Generate build.zig and main.zig first
    const build_zig = try generateBuildZig(allocator, config);
    defer allocator.free(build_zig);

    const main_zig = try generateMainZig(allocator, config, prefabs, enums, components, scripts, hooks, task_hooks);
    defer allocator.free(main_zig);

    // Create output directory path
    const output_dir_path = try std.fs.path.join(allocator, &.{ project_path, config.getOutputDir() });
    defer allocator.free(output_dir_path);

    // Ensure output directory exists
    const cwd = std.fs.cwd();
    cwd.makeDir(output_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // File paths
    // build.zig and build.zig.zon go in output directory
    const build_zig_zon_path = try std.fs.path.join(allocator, &.{ output_dir_path, "build.zig.zon" });
    defer allocator.free(build_zig_zon_path);
    const build_zig_path = try std.fs.path.join(allocator, &.{ output_dir_path, "build.zig" });
    defer allocator.free(build_zig_path);
    // main.zig stays in project root (needs project-relative imports for prefabs, components, scripts, scenes)
    const main_zig_path = try std.fs.path.join(allocator, &.{ project_path, "main.zig" });
    defer allocator.free(main_zig_path);

    // Generate build.zig.zon with placeholder fingerprint first (skip hash fetching on first pass)
    const initial_build_zig_zon = try generateBuildZon(allocator, config, .{
        .engine_path = options.engine_path,
        .engine_version = effective_engine_version,
        .fingerprint = null, // placeholder 0x0
        .fetch_hashes = false, // Skip hashes on first pass to detect fingerprint quickly
    });
    defer allocator.free(initial_build_zig_zon);

    // Write all files
    try cwd.writeFile(.{ .sub_path = build_zig_zon_path, .data = initial_build_zig_zon });
    try cwd.writeFile(.{ .sub_path = build_zig_path, .data = build_zig });
    try cwd.writeFile(.{ .sub_path = main_zig_path, .data = main_zig });

    // Run zig build to get the correct fingerprint from the error message
    const fingerprint = try detectFingerprint(allocator, output_dir_path);

    // Regenerate build.zig.zon with correct fingerprint and fetch hashes if enabled
    const final_build_zig_zon = try generateBuildZon(allocator, config, .{
        .engine_path = options.engine_path,
        .engine_version = effective_engine_version,
        .fingerprint = fingerprint,
        .fetch_hashes = options.fetch_hashes,
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
