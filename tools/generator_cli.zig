// ============================================================================
// Labelle CLI Tool
// ============================================================================
// Main entry point for the labelle command-line interface.
//
// Usage:
//   labelle <command> [options] [project_path]
//
// Commands:
//   generate    Generate project files from project.labelle (default)
//   build       Build the project
//   run         Build and run the project
//   update      Clear caches and regenerate for current CLI version
//
// Generate Options:
//   --main-only           Only generate main.zig (not build.zig or build.zig.zon)
//   --all                 Generate all files (default for new projects)
//   --engine-path <path>  Use local path to labelle-engine (for development)
//   --no-fetch            Skip fetching dependency hashes (faster, offline)
//
// If no command is provided, defaults to 'generate'.
// If no path is provided, uses current directory.
//
// Note: iOS commands have been moved to labelle-cli.

const std = @import("std");
const generator = @import("generator.zig");

// Version from build.zig.zon (imported as module)
const build_zon = @import("build_zon");
const version = build_zon.version;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // No args = default to 'generate' command
    if (args.len < 2) {
        try handleGenerate(allocator, &.{});
        return;
    }

    const command = args[1];

    // Dispatch to command handlers
    if (std.mem.eql(u8, command, "generate")) {
        try handleGenerate(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "build")) {
        try handleBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "run")) {
        try handleRun(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "update")) {
        try handleUpdate(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printHelp();
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("labelle {s}\n", .{version});
    } else if (std.mem.startsWith(u8, command, "-")) {
        // Flags without command = generate with flags
        try handleGenerate(allocator, args[1..]);
    } else {
        // Assume it's a path = generate with path
        try handleGenerate(allocator, args[1..]);
    }
}

fn printHelp() void {
    std.debug.print(
        \\labelle - Labelle Engine CLI
        \\
        \\Usage: labelle <command> [options] [project_path]
        \\
        \\Commands:
        \\  generate    Generate project files from project.labelle (default)
        \\  build       Build the project
        \\  run         Build and run the project
        \\  update      Clear caches and regenerate for current CLI version
        \\
        \\Generate Options:
        \\  --main-only           Only generate main.zig
        \\  --all                 Generate all files (default)
        \\  --engine-path <path>  Use local labelle-engine path
        \\  --no-fetch            Skip fetching dependency hashes
        \\
        \\Examples:
        \\  labelle                      # Generate in current directory
        \\  labelle generate ./my-game   # Generate for specific project
        \\  labelle build                # Build the project
        \\  labelle run                  # Build and run
        \\
        \\Note: For iOS commands, use labelle-cli: labelle ios --help
        \\
    , .{});
}

// ============================================================================
// Command Handlers
// ============================================================================

fn handleGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var main_only = false;
    var engine_path: ?[]const u8 = null;
    var fetch_hashes = true;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--main-only")) {
            main_only = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            main_only = false;
        } else if (std.mem.eql(u8, arg, "--engine-path")) {
            i += 1;
            if (i < args.len) {
                engine_path = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            engine_path = arg["--engine-path=".len..];
        } else if (std.mem.eql(u8, arg, "--no-fetch")) {
            fetch_hashes = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    if (main_only) {
        std.debug.print("Generating main.zig for: {s}\n", .{project_path});
        generator.generateMainOnly(allocator, project_path) catch |err| {
            std.debug.print("Error generating main.zig: {}\n", .{err});
            return err;
        };
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - main.zig\n", .{});
    } else {
        std.debug.print("Generating project files for: {s}\n", .{project_path});
        generator.generateProject(allocator, project_path, .{
            .engine_path = engine_path,
            .engine_version = version,
            .fetch_hashes = fetch_hashes,
        }) catch |err| {
            std.debug.print("Error generating project: {}\n", .{err});
            return err;
        };
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - build.zig.zon\n", .{});
        std.debug.print("  - build.zig\n", .{});
        std.debug.print("  - main.zig\n", .{});
    }
}

fn handleBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var zig_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer zig_args.deinit(allocator);

    // Parse args - everything after -- goes to zig build
    var i: usize = 0;
    var passthrough = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (passthrough) {
            try zig_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        } else {
            // Pass other flags to zig build
            try zig_args.append(allocator, arg);
        }
    }

    // Regenerate main.zig to ensure it's up to date
    std.debug.print("Regenerating main.zig...\n", .{});
    generator.generateMainOnly(allocator, project_path) catch |err| {
        std.debug.print("Warning: Could not regenerate main.zig: {}\n", .{err});
    };

    // Get output directory from project config
    const output_dir = generator.getOutputDir(allocator, project_path) catch ".labelle";

    // Build command: zig build [args]
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer cmd_args.deinit(allocator);

    try cmd_args.append(allocator, "zig");
    try cmd_args.append(allocator, "build");
    try cmd_args.appendSlice(allocator, zig_args.items);

    std.debug.print("Building project...\n", .{});

    // Change to output directory and run zig build
    var child = std.process.Child.init(cmd_args.items, allocator);
    child.cwd = output_dir;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        std.process.exit(if (term == .Exited) term.Exited else 1);
    }
}

fn handleRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var zig_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer zig_args.deinit(allocator);

    // Parse args
    var i: usize = 0;
    var passthrough = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (passthrough) {
            try zig_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        } else {
            try zig_args.append(allocator, arg);
        }
    }

    // Regenerate main.zig
    std.debug.print("Regenerating main.zig...\n", .{});
    generator.generateMainOnly(allocator, project_path) catch |err| {
        std.debug.print("Warning: Could not regenerate main.zig: {}\n", .{err});
    };

    // Get output directory
    const output_dir = generator.getOutputDir(allocator, project_path) catch ".labelle";

    // Build command: zig build run [args]
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer cmd_args.deinit(allocator);

    try cmd_args.append(allocator, "zig");
    try cmd_args.append(allocator, "build");
    try cmd_args.append(allocator, "run");
    try cmd_args.appendSlice(allocator, zig_args.items);

    std.debug.print("Building and running project...\n", .{});

    var child = std.process.Child.init(cmd_args.items, allocator);
    child.cwd = output_dir;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        std.process.exit(if (term == .Exited) term.Exited else 1);
    }
}

fn handleUpdate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var engine_path: ?[]const u8 = null;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--engine-path")) {
            i += 1;
            if (i < args.len) engine_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            engine_path = arg["--engine-path=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    // Get output directory
    const output_dir = generator.getOutputDir(allocator, project_path) catch ".labelle";

    // Clear .zig-cache in output directory
    const cache_path = try std.fs.path.join(allocator, &.{ output_dir, ".zig-cache" });
    defer allocator.free(cache_path);

    std.debug.print("Clearing cache: {s}\n", .{cache_path});
    std.fs.cwd().deleteTree(cache_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Warning: Could not clear cache: {}\n", .{err});
        }
    };

    // Regenerate all project files
    std.debug.print("Regenerating project files for: {s}\n", .{project_path});
    generator.generateProject(allocator, project_path, .{
        .engine_path = engine_path,
        .engine_version = version,
        .fetch_hashes = true,
    }) catch |err| {
        std.debug.print("Error generating project: {}\n", .{err});
        return err;
    };

    std.debug.print("Update complete. Generated:\n", .{});
    std.debug.print("  - build.zig.zon\n", .{});
    std.debug.print("  - build.zig\n", .{});
    std.debug.print("  - main.zig\n", .{});
}
