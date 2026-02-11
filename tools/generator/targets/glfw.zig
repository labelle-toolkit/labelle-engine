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

const main_bgfx_tmpl = @embedFile("../../templates/main_bgfx.txt");
const main_wgpu_native_tmpl = @embedFile("../../templates/main_wgpu_native.txt");

/// Generate main.zig content for bgfx backend
pub fn generateMainZigBgfx(
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

/// Generate main.zig content for wgpu_native backend
pub fn generateMainZigWgpuNative(
    allocator: std.mem.Allocator,
    config: ProjectConfig,
    prefabs: []const []const u8,
    enums: []const []const u8,
    components: []const []const u8,
    scripts: []const []const u8,
    hooks: []const []const u8,
    task_hooks: TaskHookScanResult,
) ![]const u8 {
    return generateMainZigGlfw(main_wgpu_native_tmpl, false, allocator, config, prefabs, enums, components, scripts, hooks, task_hooks);
}

/// Generic main.zig generator for GLFW-based backends (bgfx, wgpu_native)
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
        enum_pascal_names[i] = try toPascalCase(name);
    }

    // Pre-compute PascalCase names for components
    var component_pascal_names = try allocator.alloc(PascalCaseResult, components.len);
    defer allocator.free(component_pascal_names);
    for (components, 0..) |name, i| {
        component_pascal_names[i] = try toPascalCase(name);
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
        const bind_enum_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        try zts.print(template, "task_engine_start", .{ plugin_zig_name, id_type, bind_enum_type }, writer);
        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(template, "task_engine_hook_item", .{name}, writer);
        }
        try zts.print(template, "task_engine_end", .{ plugin_zig_name, id_type, bind_enum_type, plugin_zig_name, id_type, bind_enum_type }, writer);
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
