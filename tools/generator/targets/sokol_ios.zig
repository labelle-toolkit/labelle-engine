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

const main_sokol_ios_tmpl = @embedFile("../../templates/main_sokol_ios.txt");

/// Generate main.zig content for sokol backend on iOS
/// Uses callback architecture with embedded config (no runtime file loading)
pub fn generateMainZigSokolIos(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    // iOS sokol templates don't have enum/bind sections yet
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
    try zts.print(main_sokol_ios_tmpl, "header", .{config.name}, writer);

    // Plugin imports
    for (config.plugins, 0..) |plugin, i| {
        try zts.print(main_sokol_ios_tmpl, "plugin_import", .{ plugin_zig_names[i], plugin.name }, writer);
    }

    // Prefab imports
    for (prefabs) |name| {
        try zts.print(main_sokol_ios_tmpl, "prefab_import", .{ name, name }, writer);
    }

    // Component imports
    for (components) |name| {
        try zts.print(main_sokol_ios_tmpl, "component_import", .{ name, name }, writer);
    }

    // Component exports (with PascalCase type names)
    for (components, 0..) |name, i| {
        const pascal = component_pascal_names[i];
        try zts.print(main_sokol_ios_tmpl, "component_export", .{ pascal.buf[0..pascal.len], name, pascal.buf[0..pascal.len] }, writer);
    }

    // Script imports
    for (scripts) |name| {
        try zts.print(main_sokol_ios_tmpl, "script_import", .{ name, name }, writer);
    }

    // Hook imports
    for (hooks) |name| {
        try zts.print(main_sokol_ios_tmpl, "hook_import", .{ name, name }, writer);
    }

    // Main module reference
    try zts.print(main_sokol_ios_tmpl, "main_module", .{}, writer);

    // Prefab registry
    if (prefabs.len == 0) {
        try zts.print(main_sokol_ios_tmpl, "prefab_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_ios_tmpl, "prefab_registry_start", .{}, writer);
        for (prefabs) |name| {
            try zts.print(main_sokol_ios_tmpl, "prefab_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sokol_ios_tmpl, "prefab_registry_end", .{}, writer);
    }

    // Component registry - use ComponentRegistryMulti when plugins contribute Components
    if (has_plugin_components) {
        if (components.len == 0) {
            try zts.print(main_sokol_ios_tmpl, "component_registry_multi_empty_start", .{}, writer);
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_sokol_ios_tmpl, "component_registry_multi_physics", .{}, writer);
            }
            try zts.print(main_sokol_ios_tmpl, "component_registry_multi_empty_base_end", .{}, writer);
        } else {
            try zts.print(main_sokol_ios_tmpl, "component_registry_multi_start", .{}, writer);
            for (components, 0..) |_, i| {
                const pascal = component_pascal_names[i];
                try zts.print(main_sokol_ios_tmpl, "component_registry_multi_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_sokol_ios_tmpl, "component_registry_multi_physics_start", .{}, writer);
            }
            try zts.print(main_sokol_ios_tmpl, "component_registry_multi_base_end", .{}, writer);
        }
        // Add plugin component types
        for (config.plugins, 0..) |plugin, i| {
            if (plugin.components) |components_expr| {
                try zts.print(main_sokol_ios_tmpl, "component_registry_multi_plugin", .{ plugin_zig_names[i], components_expr }, writer);
            }
        }
        try zts.print(main_sokol_ios_tmpl, "component_registry_multi_end", .{}, writer);
    } else {
        // Simple ComponentRegistry
        if (components.len == 0) {
            try zts.print(main_sokol_ios_tmpl, "component_registry_empty", .{}, writer);
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_sokol_ios_tmpl, "physics_components", .{}, writer);
            }
            try zts.print(main_sokol_ios_tmpl, "component_registry_empty_end", .{}, writer);
        } else {
            try zts.print(main_sokol_ios_tmpl, "component_registry_start", .{}, writer);
            for (components, 0..) |_, i| {
                const pascal = component_pascal_names[i];
                try zts.print(main_sokol_ios_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_sokol_ios_tmpl, "component_registry_physics", .{}, writer);
            }
            try zts.print(main_sokol_ios_tmpl, "component_registry_end", .{}, writer);
        }
    }

    // Script registry
    if (scripts.len == 0) {
        try zts.print(main_sokol_ios_tmpl, "script_registry_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_ios_tmpl, "script_registry_start", .{}, writer);
        for (scripts) |name| {
            try zts.print(main_sokol_ios_tmpl, "script_registry_item", .{ name, name }, writer);
        }
        try zts.print(main_sokol_ios_tmpl, "script_registry_end", .{}, writer);
    }

    // Hooks
    if (hooks.len == 0) {
        try zts.print(main_sokol_ios_tmpl, "hooks_empty", .{}, writer);
    } else {
        try zts.print(main_sokol_ios_tmpl, "hooks_start", .{}, writer);
        for (hooks) |name| {
            try zts.print(main_sokol_ios_tmpl, "hooks_item", .{name}, writer);
        }
        try zts.print(main_sokol_ios_tmpl, "hooks_end", .{}, writer);
    }

    // Task engine hooks (if any)
    // Note: This is legacy support - prefer using engine_hooks config on plugins
    const ios_game_id_str = switch (config.game_id) {
        .u32 => "u32",
        .u64 => "u64",
    };
    if (task_hooks.has_task_hooks and task_hooks.tasks_plugin != null) {
        const plugin = task_hooks.tasks_plugin.?;
        const plugin_zig_name = try sanitizeZigIdentifier(allocator, plugin.name);
        defer allocator.free(plugin_zig_name);
        const id_type = ios_game_id_str;
        const bind_enum_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        try zts.print(main_sokol_ios_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, bind_enum_type }, writer);
        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_sokol_ios_tmpl, "task_engine_hook_item", .{name}, writer);
        }
        try zts.print(main_sokol_ios_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, bind_enum_type, plugin_zig_name, id_type, bind_enum_type }, writer);
    } else {
        try zts.print(main_sokol_ios_tmpl, "task_engine_empty", .{}, writer);
    }

    // Loader and scene
    try zts.print(main_sokol_ios_tmpl, "loader", .{config.initial_scene}, writer);

    // State
    try zts.print(main_sokol_ios_tmpl, "state", .{}, writer);

    // Init callback with embedded config
    const target_fps: u32 = @intCast(config.window.target_fps);
    try zts.print(main_sokol_ios_tmpl, "init_cb", .{ config.window.width, config.window.height, config.window.title, target_fps }, writer);

    // Camera config (only if non-default)
    if (config.camera.x != null or config.camera.y != null or config.camera.zoom != 1.0) {
        const cam_x: f32 = config.camera.x orelse 0;
        const cam_y: f32 = config.camera.y orelse 0;
        try zts.print(main_sokol_ios_tmpl, "camera_config", .{ cam_x, cam_y, config.camera.zoom }, writer);
        try zts.print(main_sokol_ios_tmpl, "camera_config_end", .{}, writer);
    }

    // Rest of init callback (scene loading)
    try zts.print(main_sokol_ios_tmpl, "init_cb_end", .{}, writer);

    // Frame and cleanup callbacks
    try zts.print(main_sokol_ios_tmpl, "frame_cb", .{}, writer);
    try zts.print(main_sokol_ios_tmpl, "cleanup_cb", .{}, writer);
    try zts.print(main_sokol_ios_tmpl, "event_cb", .{}, writer);

    // Main function with embedded window config
    try zts.print(main_sokol_ios_tmpl, "main_fn", .{ config.window.width, config.window.height, config.window.title }, writer);

    return buf.toOwnedSlice(allocator);
}
