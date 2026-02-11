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

const main_raylib_tmpl = @embedFile("../../templates/main_raylib.txt");

/// Generate main.zig content based on folder contents (raylib backend)
pub fn generateMainZigRaylib(
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
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_raylib_tmpl, "component_registry_multi_physics", .{}, writer);
            }
            try zts.print(main_raylib_tmpl, "component_registry_multi_empty_base_end", .{}, writer);
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

            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_raylib_tmpl, "component_registry_multi_physics", .{}, writer);
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
        // Add physics components if physics is enabled
        if (config.physics.enabled) {
            try zts.print(main_raylib_tmpl, "component_registry_physics", .{}, writer);
        }
        try zts.print(main_raylib_tmpl, "component_registry_end", .{}, writer);
    } else {
        // No plugins - use simple ComponentRegistry
        if (components.len == 0) {
            try zts.print(main_raylib_tmpl, "component_registry_empty", .{}, writer);
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_raylib_tmpl, "physics_components", .{}, writer);
            }
            try zts.print(main_raylib_tmpl, "component_registry_empty_end", .{}, writer);
        } else {
            try zts.print(main_raylib_tmpl, "component_registry_start", .{}, writer);
            for (component_pascal_names) |pascal| {
                try zts.print(main_raylib_tmpl, "component_registry_item", .{ pascal.buf[0..pascal.len], pascal.buf[0..pascal.len] }, writer);
            }
            // Add physics components if physics is enabled
            if (config.physics.enabled) {
                try zts.print(main_raylib_tmpl, "component_registry_physics", .{}, writer);
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

            // Get bind enum type: use explicit item_arg if specified, otherwise first bind arg
            const bind_enum_type = eh.item_arg orelse (if (plugin.bind.len > 0) plugin.bind[0].arg else "void");

            // Generate: const plugin_engine_hooks = plugin.createEngineHooks(GameId, BindEnumType, hook_file.GameHooks);
            // Template args: plugin_zig_name, plugin_zig_name, create_fn, bind_enum_type, hook_file, struct_name
            //                plugin_zig_name (for Context export prefix), plugin_zig_name
            try zts.print(main_raylib_tmpl, "plugin_engine_hooks", .{
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
        const bind_enum_type =
            (if (plugin.bind.len > 0) plugin.bind[0].arg else null) orelse
            @panic("labelle-tasks plugin requires bind declaration when task hooks are detected");

        // Generate TaskEngine type
        try zts.print(main_raylib_tmpl, "task_engine_start", .{ plugin_zig_name, id_type, bind_enum_type }, writer);

        for (task_hooks.hook_files_with_tasks) |name| {
            try zts.print(main_raylib_tmpl, "task_engine_hook_item", .{name}, writer);
        }

        try zts.print(main_raylib_tmpl, "task_engine_end", .{ plugin_zig_name, id_type, bind_enum_type, plugin_zig_name, id_type, bind_enum_type }, writer);
    } else {
        try zts.print(main_raylib_tmpl, "task_engine_empty", .{}, writer);
    }

    // Loader and initial scene
    try zts.print(main_raylib_tmpl, "loader", .{config.initial_scene}, writer);

    // Main function (desktop reads config from project.labelle at runtime)
    try zts.print(main_raylib_tmpl, "main_fn", .{}, writer);

    return buf.toOwnedSlice(allocator);
}
