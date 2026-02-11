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

const main_sokol_tmpl = @embedFile("../../templates/main_sokol.txt");

/// Generate main.zig content for sokol backend
pub fn generateMainZigSokol(
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
        component_pascal_names[i] = try toPascalCase(name);
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
        const bind_enum_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        // Generate TaskEngine type
        try zts.print(main_sokol_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, bind_enum_type }, writer);

        // Add hook files that contain task hooks
        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_sokol_tmpl, "task_engine_hook_item", .{name}, writer);
        }

        try zts.print(main_sokol_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, bind_enum_type, plugin_zig_name, id_type, bind_enum_type }, writer);
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
