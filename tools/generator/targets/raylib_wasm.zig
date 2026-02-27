const std = @import("std");
const zts = @import("zts");
const project_config = @import("../../project_config.zig");
const utils = @import("../utils.zig");
const scanner = @import("../scanner.zig");

const ProjectConfig = project_config.ProjectConfig;
const sanitizeZigIdentifier = utils.sanitizeZigIdentifier;
const PascalCaseResult = utils.PascalCaseResult;
const toPascalCase = utils.toPascalCase;
const TaskHookScanResult = scanner.TaskHookScanResult;

const main_raylib_wasm_tmpl = @embedFile("../../templates/main_raylib_wasm.txt");

/// Generate main.zig content for raylib backend targeting WASM
pub fn generateMainZigRaylibWasm(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    // Use the same logic as desktop raylib but with WASM template (simpler, no conditionals)
    // This is almost identical to generateMainZigRaylib, but uses main_raylib_wasm_tmpl
    _ = task_hooks; // Legacy task hooks are not used - use engine_hooks config on plugins instead

    var buf: std.ArrayListUnmanaged(u8) = .{};
    const writer = buf.writer(allocator);

    // Check if any plugin contributes Components or has bindings
    var has_plugin_components = false;
    for (config.plugins) |plugin| {
        if (plugin.components != null) {
            has_plugin_components = true;
        }
    }

    // Pre-compute sanitized plugin names
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
        enum_pascal_names[i] = try toPascalCase(name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = try toPascalCase(name);
    }

    // Header
    try zts.print(main_raylib_wasm_tmpl, "header", .{config.name}, writer);

    // Plugin imports
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(main_raylib_wasm_tmpl, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Enum imports
    for (enums) |name| {
        try zts.print(main_raylib_wasm_tmpl, "enum_import", .{ name, name }, writer);
    }

    // Enum exports (with PascalCase type names)
    for (enums, 0..) |name, i| {
        const pascal = enum_pascal_names[i];
        try zts.print(main_raylib_wasm_tmpl, "enum_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // GameId type export
    const game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    try zts.print(main_raylib_wasm_tmpl, "game_id_export", .{game_id_str}, writer);

    // Plugin bind declarations
    for (config.plugins, 0..) |plugin, i| {
        for (plugin.bind) |bind_decl| {
            try zts.print(main_raylib_wasm_tmpl, "plugin_bind", .{ plugin_zig_names[i], bind_decl.arg, plugin_zig_names[i], bind_decl.func, bind_decl.arg }, writer);
        }
    }

    // Plugin engine hooks - first pass: count and track which hook files are used by plugins
    // This must happen BEFORE hook imports so we can filter them
    // The actual output happens AFTER hook imports (see below)
    var plugin_engine_hooks_count: usize = 0;
    var hook_files_used_by_plugins = std.StringHashMap(void).init(allocator);
    defer hook_files_used_by_plugins.deinit();

    for (config.plugins) |plugin| {
        if (plugin.engine_hooks) |eh| {
            plugin_engine_hooks_count += 1;

            // Parse the hooks reference to get hook file and struct name
            var it = std.mem.splitScalar(u8, eh.hooks, '.');
            const hook_file = it.next() orelse continue;

            // Mark this hook file as used by a plugin
            hook_files_used_by_plugins.put(hook_file, {}) catch {};
        }
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_raylib_wasm_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_raylib_wasm_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(main_raylib_wasm_tmpl, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_raylib_wasm_tmpl, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(main_raylib_wasm_tmpl, "hook_import", .{ name, name }, writer);
    }

    // Plugin engine hooks - second pass: output the createEngineHooks calls
    // This must happen AFTER hook imports since we reference the hook file
    for (config.plugins, 0..) |plugin, i| {
        if (plugin.engine_hooks) |eh| {
            // Parse the hooks reference to get hook file and struct name
            var it = std.mem.splitScalar(u8, eh.hooks, '.');
            const hook_file = it.next() orelse continue;
            const struct_name = it.next() orelse "GameHooks";

            if (eh.args.len > 0) {
                // New path: explicit args list (e.g., labelle-needs with .args = .{"Needs", "Items"})
                try writer.print("const {s}_engine_hooks = {s}.{s}(GameId", .{
                    plugin_zig_names[i], plugin_zig_names[i], eh.create,
                });
                for (eh.args) |arg| {
                    try writer.print(", {s}", .{arg});
                }
                try writer.print(", {s}_hooks.{s}, engine.EngineTypes);\n", .{ hook_file, struct_name });
                try writer.print("pub const {s}Context = {s}_engine_hooks.Context;\n", .{
                    plugin_zig_names[i], plugin_zig_names[i],
                });
            } else {
                // Legacy path: use item_arg or first bind arg as single type arg
                const bind_enum_type = eh.item_arg orelse (if (plugin.bind.len > 0) plugin.bind[0].arg else "void");

                try zts.print(main_raylib_wasm_tmpl, "plugin_engine_hooks", .{
                    plugin_zig_names[i], // for const name
                    plugin_zig_names[i], // for plugin module
                    eh.create, // createEngineHooks
                    bind_enum_type, // Enum type (e.g., Items)
                    hook_file, // task_hooks
                    struct_name, // GameHooks
                    plugin_zig_names[i], // Context prefix
                    plugin_zig_names[i], // Context value
                }, writer);
            }
        }
    }

    // Main module reference
    try zts.print(main_raylib_wasm_tmpl, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_raylib_wasm_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_wasm_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_raylib_wasm_tmpl, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_raylib_wasm_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Component registry (simplified - using single ComponentRegistry)
    if (components.len == 0) {
        try zts.print(main_raylib_wasm_tmpl, "component_registry_empty", .{}, writer);
        if (config.physics.enabled) {
            try zts.print(main_raylib_wasm_tmpl, "physics_components", .{}, writer);
        }
        try zts.print(main_raylib_wasm_tmpl, "component_registry_empty_end", .{}, writer);
    } else {
        try zts.print(main_raylib_wasm_tmpl, "component_registry_start", .{}, writer);
        for (component_pascal_names) |pascal| {
            try zts.print(main_raylib_wasm_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
        }
        // Add bind components
        for (config.plugins, 0..) |plugin, i| {
            for (plugin.bind) |bind_decl| {
                const components_list = bind_decl.components;
                var iter = std.mem.splitSequence(u8, components_list, ",");
                while (iter.next()) |comp_name| {
                    const trimmed = std.mem.trim(u8, comp_name, &std.ascii.whitespace);
                    if (trimmed.len > 0) {
                        try zts.print(main_raylib_wasm_tmpl, "component_registry_bind_item", .{ trimmed, plugin_zig_names[i], bind_decl.arg, trimmed }, writer);
                    }
                }
            }
        }
        if (config.physics.enabled) {
            try zts.print(main_raylib_wasm_tmpl, "component_registry_physics", .{}, writer);
        }
        try zts.print(main_raylib_wasm_tmpl, "component_registry_end", .{}, writer);
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(main_raylib_wasm_tmpl, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_wasm_tmpl, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(main_raylib_wasm_tmpl, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_raylib_wasm_tmpl, "script_registry_end", .{}, writer);
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
        try zts.print(main_raylib_wasm_tmpl, "hooks_empty", .{}, writer);
    } else {
        try zts.print(main_raylib_wasm_tmpl, "hooks_start", .{}, writer);

        // Include hook files that have engine hooks
        for (filtered_hooks.items) |name| {
            try zts.print(main_raylib_wasm_tmpl, "hooks_item", .{name}, writer);
        }

        // Include plugin engine hooks
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.hasEngineHooks()) {
                try zts.print(main_raylib_wasm_tmpl, "hooks_plugin_item", .{plugin_zig_names[i]}, writer);
            }
        }

        try zts.print(main_raylib_wasm_tmpl, "hooks_end", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(main_raylib_wasm_tmpl, "loader", .{config.initial_scene}, writer);

    // Main function with embedded config values
    const camera_x = config.camera.x orelse 0;
    const camera_y = config.camera.y orelse 0;
    const camera_zoom = config.camera.zoom;

    try zts.print(main_raylib_wasm_tmpl, "main_fn", .{
        config.window.title,
        config.window.width,
        config.window.height,
        config.window.target_fps,
        camera_x,
        camera_y,
    }, writer);

    // Camera zoom (optional)
    if (camera_zoom != 1.0) {
        try zts.print(main_raylib_wasm_tmpl, "camera_zoom", .{camera_zoom}, writer);
    }
    try zts.print(main_raylib_wasm_tmpl, "camera_zoom_end", .{}, writer);

    return buf.toOwnedSlice(allocator);
}
