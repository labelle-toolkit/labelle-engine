// Labelle CLI - Command-line interface for labelle-engine projects
//
// Usage:
//   labelle <command> [options]
//
// Commands:
//   init        Create a new labelle project
//   generate    Generate project files from project.labelle
//   build       Build the project
//   run         Build and run the project
//   help        Show help information
//
// Examples:
//   labelle init my-game
//   labelle generate
//   labelle build
//   labelle run
//   labelle run --release

const std = @import("std");
const generator = @import("generator.zig");
const project_config = @import("project_config.zig");

const ProjectConfig = project_config.ProjectConfig;

// Version and config from build.zig.zon (imported as module)
const build_zon = @import("build_zon");
const version = build_zon.version;
const releases_url = build_zon.releases_url;

const Command = enum {
    init,
    generate,
    build,
    run,
    update,
    upgrade,
    help,
    version,
};

const Options = struct {
    command: Command = .help,
    project_path: []const u8 = ".",
    project_name: ?[]const u8 = null,
    engine_path: ?[]const u8 = null,
    main_only: bool = false,
    release: bool = false,
    backend: ?[]const u8 = null,
    ecs_backend: ?[]const u8 = null,
    show_help: bool = false,
    /// If false, skip fetching dependency hashes (faster but requires manual hash addition)
    fetch_hashes: bool = true,
    // Upgrade command options
    upgrade_check_only: bool = false,
    upgrade_version: ?[]const u8 = null,
    upgrade_force: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = parseArgs(args);

    if (options.show_help) {
        printCommandHelp(options.command);
        return;
    }

    switch (options.command) {
        .init => try runInit(allocator, options),
        .generate => try runGenerate(allocator, options),
        .build => try runBuild(allocator, options),
        .run => try runRun(allocator, options),
        .update => try runUpdate(allocator, options),
        .upgrade => try runUpgrade(allocator, options),
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn parseArgs(args: []const []const u8) Options {
    var options = Options{};

    if (args.len < 2) {
        return options;
    }

    // Parse command
    const cmd_str = args[1];
    if (std.mem.eql(u8, cmd_str, "init")) {
        options.command = .init;
    } else if (std.mem.eql(u8, cmd_str, "generate") or std.mem.eql(u8, cmd_str, "gen")) {
        options.command = .generate;
    } else if (std.mem.eql(u8, cmd_str, "build")) {
        options.command = .build;
    } else if (std.mem.eql(u8, cmd_str, "run")) {
        options.command = .run;
    } else if (std.mem.eql(u8, cmd_str, "update")) {
        options.command = .update;
    } else if (std.mem.eql(u8, cmd_str, "upgrade")) {
        options.command = .upgrade;
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h")) {
        options.command = .help;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-v")) {
        options.command = .version;
    } else {
        // Unknown command, might be a project name for init or path
        options.project_name = cmd_str;
    }

    // Parse additional arguments
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "--main-only")) {
            options.main_only = true;
        } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            options.release = true;
        } else if (std.mem.eql(u8, arg, "--engine-path")) {
            i += 1;
            if (i < args.len) {
                options.engine_path = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            options.engine_path = arg["--engine-path=".len..];
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i < args.len) {
                options.backend = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            options.backend = arg["--backend=".len..];
        } else if (std.mem.eql(u8, arg, "--ecs-backend")) {
            i += 1;
            if (i < args.len) {
                options.ecs_backend = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--ecs-backend=")) {
            options.ecs_backend = arg["--ecs-backend=".len..];
        } else if (std.mem.eql(u8, arg, "--no-fetch")) {
            options.fetch_hashes = false;
        } else if (std.mem.eql(u8, arg, "--check") or std.mem.eql(u8, arg, "-c")) {
            options.upgrade_check_only = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.upgrade_force = true;
        } else if (std.mem.eql(u8, arg, "--version") and options.command == .upgrade) {
            i += 1;
            if (i < args.len) {
                options.upgrade_version = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--version=") and options.command == .upgrade) {
            options.upgrade_version = arg["--version=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument
            if (options.command == .init and options.project_name == null) {
                options.project_name = arg;
            } else {
                options.project_path = arg;
            }
        }
    }

    return options;
}

fn runInit(allocator: std.mem.Allocator, options: Options) !void {
    const name = options.project_name orelse {
        std.debug.print("Error: Project name required\n", .{});
        std.debug.print("Usage: labelle init <project-name>\n", .{});
        return error.MissingProjectName;
    };

    std.debug.print("Creating new labelle project: {s}\n", .{name});

    // Create project directory
    const cwd = std.fs.cwd();
    cwd.makeDir(name) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("Error: Directory '{s}' already exists\n", .{name});
            return err;
        }
        return err;
    };

    // Create subdirectories
    const subdirs = [_][]const u8{ "components", "prefabs", "scripts", "scenes", "resources" };
    for (subdirs) |subdir| {
        const path = try std.fs.path.join(allocator, &.{ name, subdir });
        defer allocator.free(path);
        try cwd.makeDir(path);
    }

    // Determine backend
    const backend_str = options.backend orelse "raylib";
    const backend: project_config.Backend = if (std.mem.eql(u8, backend_str, "sokol")) .sokol else .raylib;

    // Determine ECS backend
    const ecs_backend_str = options.ecs_backend orelse "zig_ecs";
    const ecs_backend: project_config.EcsBackend = if (std.mem.eql(u8, ecs_backend_str, "zflecs")) .zflecs else .zig_ecs;

    // Create project.labelle
    const project_labelle_path = try std.fs.path.join(allocator, &.{ name, "project.labelle" });
    defer allocator.free(project_labelle_path);

    const project_content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .version = 1,
        \\    .name = "{s}",
        \\    .description = "A labelle game project",
        \\    .initial_scene = "main",
        \\    .backend = .{s},
        \\    .ecs_backend = .{s},
        \\    .window = .{{
        \\        .width = 800,
        \\        .height = 600,
        \\        .title = "{s}",
        \\        .target_fps = 60,
        \\    }},
        \\    .resources = .{{}},
        \\    .plugins = .{{}},
        \\}}
        \\
    , .{ name, @tagName(backend), @tagName(ecs_backend), name });
    defer allocator.free(project_content);

    try cwd.writeFile(.{ .sub_path = project_labelle_path, .data = project_content });

    // Create initial scene
    const scene_path = try std.fs.path.join(allocator, &.{ name, "scenes", "main.zon" });
    defer allocator.free(scene_path);

    const scene_content =
        \\.{
        \\    .name = "main",
        \\    .entities = &.{},
        \\}
        \\
    ;
    try cwd.writeFile(.{ .sub_path = scene_path, .data = scene_content });

    // Generate build files
    std.debug.print("Generating build files...\n", .{});
    try generator.generateProject(allocator, name, .{
        .engine_path = options.engine_path,
        .engine_version = version,
        .fetch_hashes = options.fetch_hashes,
    });

    std.debug.print("\nProject created successfully!\n", .{});
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("  cd {s}\n", .{name});
    std.debug.print("  labelle run\n", .{});

    if (options.engine_path != null) {
        std.debug.print("\nNote: You used --engine-path with a local path.\n", .{});
        std.debug.print("Make sure the path in build.zig.zon is relative, not absolute.\n", .{});
    }
}

fn runGenerate(allocator: std.mem.Allocator, options: Options) !void {
    if (options.main_only) {
        std.debug.print("Generating main.zig for: {s}\n", .{options.project_path});
        generator.generateMainOnly(allocator, options.project_path) catch |err| {
            std.debug.print("Error generating main.zig: {}\n", .{err});
            return err;
        };
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - main.zig\n", .{});
    } else {
        std.debug.print("Generating project files for: {s}\n", .{options.project_path});
        generator.generateProject(allocator, options.project_path, .{
            .engine_path = options.engine_path,
            .engine_version = version,
            .fetch_hashes = options.fetch_hashes,
        }) catch |err| {
            std.debug.print("Error generating project: {}\n", .{err});
            return err;
        };
        // Get output directory for display (after successful generation)
        var must_free_output_dir = true;
        const output_dir = generator.getOutputDir(allocator, options.project_path) catch blk: {
            must_free_output_dir = false;
            break :blk ".labelle";
        };
        defer if (must_free_output_dir) allocator.free(output_dir);
        std.debug.print("Generated:\n", .{});
        std.debug.print("  - {s}/build.zig.zon\n", .{output_dir});
        std.debug.print("  - {s}/build.zig\n", .{output_dir});
        std.debug.print("  - main.zig\n", .{});
    }
}

fn runBuild(allocator: std.mem.Allocator, options: Options) !void {
    // First, ensure generated files are up to date
    std.debug.print("Ensuring generated files are up to date...\n", .{});
    generator.generateMainOnly(allocator, options.project_path) catch |err| {
        std.debug.print("Warning: Could not regenerate main.zig: {}\n", .{err});
    };

    // Get output directory where build.zig is located
    const output_dir = try generator.getOutputDir(allocator, options.project_path);
    defer allocator.free(output_dir);

    std.debug.print("Building project...\n", .{});

    // Build command arguments
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "build");

    if (options.release) {
        try argv.append(allocator, "-Doptimize=ReleaseFast");
    }

    if (options.backend) |backend| {
        const backend_arg = try std.fmt.allocPrint(allocator, "-Dbackend={s}", .{backend});
        try argv.append(allocator, backend_arg);
    }

    if (options.ecs_backend) |ecs_backend| {
        const ecs_arg = try std.fmt.allocPrint(allocator, "-Decs_backend={s}", .{ecs_backend});
        try argv.append(allocator, ecs_arg);
    }

    // Change to output directory (where build.zig is located) and run zig build
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = output_dir;

    // Inherit stdio
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

fn runRun(allocator: std.mem.Allocator, options: Options) !void {
    // First, ensure generated files are up to date
    std.debug.print("Ensuring generated files are up to date...\n", .{});
    generator.generateMainOnly(allocator, options.project_path) catch |err| {
        std.debug.print("Warning: Could not regenerate main.zig: {}\n", .{err});
    };

    // Get output directory where build.zig is located
    const output_dir = try generator.getOutputDir(allocator, options.project_path);
    defer allocator.free(output_dir);

    std.debug.print("Building and running project...\n", .{});

    // Build command arguments
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "build");
    try argv.append(allocator, "run");

    if (options.release) {
        try argv.append(allocator, "-Doptimize=ReleaseFast");
    }

    if (options.backend) |backend| {
        const backend_arg = try std.fmt.allocPrint(allocator, "-Dbackend={s}", .{backend});
        try argv.append(allocator, backend_arg);
    }

    if (options.ecs_backend) |ecs_backend| {
        const ecs_arg = try std.fmt.allocPrint(allocator, "-Decs_backend={s}", .{ecs_backend});
        try argv.append(allocator, ecs_arg);
    }

    // Change to output directory (where build.zig is located) and run zig build run
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = output_dir;

    // Inherit stdio
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

fn runUpdate(allocator: std.mem.Allocator, options: Options) !void {
    std.debug.print("Updating project to labelle-engine {s}...\n", .{version});

    // Get output directory
    const output_dir = try generator.getOutputDir(allocator, options.project_path);
    defer allocator.free(output_dir);

    // Clear cache directories
    std.debug.print("Clearing cache directories...\n", .{});
    const cache_dirs = [_][]const u8{ "zig-cache", ".zig-cache", "zig-out" };
    const cwd = std.fs.cwd();

    for (cache_dirs) |cache_dir| {
        // Try to delete in project root
        const project_cache = try std.fs.path.join(allocator, &.{ options.project_path, cache_dir });
        cwd.deleteTree(project_cache) catch {};
        allocator.free(project_cache);

        // Try to delete in output directory
        const output_cache = try std.fs.path.join(allocator, &.{ output_dir, cache_dir });
        cwd.deleteTree(output_cache) catch {};
        allocator.free(output_cache);
    }

    // Regenerate project files
    std.debug.print("Regenerating project files...\n", .{});
    try generator.generateProject(allocator, options.project_path, .{
        .engine_path = options.engine_path,
        .engine_version = version,
        .fetch_hashes = options.fetch_hashes,
    });

    std.debug.print("Update complete!\n", .{});
    std.debug.print("  - Cleared cache directories\n", .{});
    std.debug.print("  - Regenerated build files for labelle-engine {s}\n", .{version});
}

fn runUpgrade(allocator: std.mem.Allocator, options: Options) !void {
    std.debug.print("Checking for updates...\n", .{});

    // Fetch latest release info from GitHub
    const release_info = fetchLatestRelease(allocator) catch |err| {
        std.debug.print("Error: Could not fetch release information from GitHub.\n", .{});
        std.debug.print("Please check your internet connection and try again.\n", .{});
        if (err == error.ConnectionRefused or err == error.NetworkUnreachable) {
            std.debug.print("Network error: {}\n", .{err});
        }
        return err;
    };
    defer release_info.deinit(allocator);

    const target_version = options.upgrade_version orelse release_info.tag_name;

    std.debug.print("Current version: {s}\n", .{version});
    std.debug.print("Latest version:  {s}\n", .{release_info.tag_name});
    if (options.upgrade_version) |v| {
        std.debug.print("Target version:  {s}\n", .{v});
    }
    std.debug.print("\n", .{});

    // Compare versions
    const is_latest = std.mem.eql(u8, version, stripVersionPrefix(target_version));
    if (is_latest and !options.upgrade_force) {
        std.debug.print("You are already on the latest version!\n", .{});
        return;
    }

    if (options.upgrade_check_only) {
        if (!is_latest) {
            std.debug.print("A new version is available: {s}\n", .{target_version});
            std.debug.print("Run 'labelle upgrade' to install it.\n", .{});
        }
        return;
    }

    // Get platform-specific asset
    const platform = getPlatformString();
    std.debug.print("Downloading labelle {s} for {s}...\n", .{ target_version, platform });

    // Find the matching asset
    const asset = findAsset(release_info.assets, platform) orelse {
        std.debug.print("Error: No pre-built binary available for {s}.\n", .{platform});
        std.debug.print("Please build from source or check available releases.\n", .{});
        return error.NoBinaryForPlatform;
    };

    // Download the binary
    const binary_data = downloadAsset(allocator, asset.url) catch |err| {
        std.debug.print("Error downloading binary: {}\n", .{err});
        return err;
    };
    defer allocator.free(binary_data);

    // Get current executable path
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch |err| {
        std.debug.print("Error: Could not determine executable path: {}\n", .{err});
        return err;
    };

    std.debug.print("Installing to {s}...\n", .{exe_path});

    // Write the new binary (replace current executable)
    installBinary(allocator, exe_path, binary_data, asset.name) catch |err| {
        std.debug.print("Error installing binary: {}\n", .{err});
        std.debug.print("You may need to run with elevated privileges (sudo).\n", .{});
        return err;
    };

    std.debug.print("\nSuccessfully upgraded to {s}!\n", .{target_version});
}

var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;

const ReleaseInfo = struct {
    tag_name: []const u8,
    assets: []const Asset,

    const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
    };

    fn deinit(self: ReleaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.tag_name);
        for (self.assets) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.browser_download_url);
        }
        allocator.free(self.assets);
    }
};

fn fetchLatestRelease(allocator: std.mem.Allocator) !ReleaseInfo {
    const url = releases_url;

    // Use curl to fetch the release info (handles HTTPS properly)
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-s", // silent
            "-H",
            "User-Agent: labelle-cli",
            "-H",
            "Accept: application/vnd.github.v3+json",
            url,
        },
    }) catch |err| {
        std.debug.print("Failed to run curl: {}\n", .{err});
        return error.CurlFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.CurlFailed;
    }

    return parseReleaseJson(allocator, result.stdout);
}

fn parseReleaseJson(allocator: std.mem.Allocator, json_data: []const u8) !ReleaseInfo {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch {
        return error.JsonParseError;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Get tag_name
    const tag_name_value = root.get("tag_name") orelse return error.MissingTagName;
    const tag_name = try allocator.dupe(u8, tag_name_value.string);
    errdefer allocator.free(tag_name);

    // Get assets
    const assets_value = root.get("assets") orelse return error.MissingAssets;
    const assets_array = assets_value.array;

    var assets = try allocator.alloc(ReleaseInfo.Asset, assets_array.items.len);
    errdefer allocator.free(assets);

    var asset_count: usize = 0;
    for (assets_array.items) |asset_value| {
        const asset_obj = asset_value.object;
        const name_val = asset_obj.get("name") orelse continue;
        const url_val = asset_obj.get("browser_download_url") orelse continue;

        assets[asset_count] = .{
            .name = try allocator.dupe(u8, name_val.string),
            .browser_download_url = try allocator.dupe(u8, url_val.string),
        };
        asset_count += 1;
    }

    // Shrink to actual size
    assets = try allocator.realloc(assets, asset_count);

    return .{
        .tag_name = tag_name,
        .assets = assets,
    };
}

fn getPlatformString() []const u8 {
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);

    // Map to common naming conventions
    if (builtin.os.tag == .macos) {
        if (builtin.cpu.arch == .aarch64) {
            return "darwin-arm64";
        } else {
            return "darwin-x86_64";
        }
    } else if (builtin.os.tag == .linux) {
        if (builtin.cpu.arch == .x86_64) {
            return "linux-x86_64";
        } else if (builtin.cpu.arch == .aarch64) {
            return "linux-arm64";
        }
    } else if (builtin.os.tag == .windows) {
        return "windows-x86_64";
    }

    // Fallback to raw names
    _ = os;
    _ = arch;
    return "unknown";
}

const AssetInfo = struct {
    url: []const u8,
    name: []const u8,
};

fn findAsset(assets: []const ReleaseInfo.Asset, platform: []const u8) ?AssetInfo {
    for (assets) |asset| {
        // Look for asset matching platform (e.g., "labelle-darwin-arm64" or "labelle-darwin-arm64.tar.gz")
        if (std.mem.indexOf(u8, asset.name, platform) != null) {
            return .{ .url = asset.browser_download_url, .name = asset.name };
        }
    }
    return null;
}

fn downloadAsset(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Use curl to download the asset (handles redirects and HTTPS properly)
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-s",    // silent
            "-L",    // follow redirects
            "-f",    // fail on HTTP errors
            url,
        },
        .max_output_bytes = 50 * 1024 * 1024,
    }) catch |err| {
        std.debug.print("Failed to run curl: {}\n", .{err});
        return error.DownloadFailed;
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.DownloadFailed;
    }

    return result.stdout;
}

fn installBinary(allocator: std.mem.Allocator, exe_path: []const u8, binary_data: []const u8, asset_name: []const u8) !void {
    // Check if this is a tar.gz archive based on filename
    if (std.mem.endsWith(u8, asset_name, ".tar.gz") or std.mem.endsWith(u8, asset_name, ".tgz")) {
        // Extract using tar command
        try installFromTarGz(allocator, exe_path, binary_data);
    } else {
        // Raw binary - install directly
        try installRawBinary(exe_path, binary_data);
    }
}

fn installRawBinary(exe_path: []const u8, binary_data: []const u8) !void {
    // Create backup of current binary
    var backup_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = std.fmt.bufPrint(&backup_path_buf, "{s}.bak", .{exe_path}) catch return error.PathTooLong;

    const cwd = std.fs.cwd();

    // Remove old backup if exists
    cwd.deleteFile(backup_path) catch {};

    // Rename current to backup
    cwd.rename(exe_path, backup_path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };

    // Write new binary
    const file = try cwd.createFile(exe_path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(binary_data);

    // Remove backup on success
    cwd.deleteFile(backup_path) catch {};
}

fn installFromTarGz(allocator: std.mem.Allocator, exe_path: []const u8, compressed_data: []const u8) !void {
    // Write compressed data to temp file
    const tmp_dir = std.fs.cwd();
    const tmp_archive = ".labelle-upgrade.tar.gz";
    const tmp_extracted = ".labelle-upgrade-extracted";

    // Write the archive
    {
        const file = try tmp_dir.createFile(tmp_archive, .{});
        defer file.close();
        try file.writeAll(compressed_data);
    }
    defer tmp_dir.deleteFile(tmp_archive) catch {};

    // Create extraction directory
    tmp_dir.makeDir(tmp_extracted) catch {};
    defer tmp_dir.deleteTree(tmp_extracted) catch {};

    // Extract using tar
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "tar",
            "-xzf",
            tmp_archive,
            "-C",
            tmp_extracted,
        },
    }) catch {
        return error.TarExtractionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.TarExtractionFailed;
    }

    // Find the labelle binary in extracted files
    var extracted_dir = try tmp_dir.openDir(tmp_extracted, .{ .iterate = true });
    defer extracted_dir.close();

    var iter = extracted_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.indexOf(u8, entry.name, "labelle") != null and entry.kind == .file) {
            // Read the extracted binary
            const extracted_file = try extracted_dir.openFile(entry.name, .{});
            defer extracted_file.close();

            const stat = try extracted_file.stat();
            const binary_data = try allocator.alloc(u8, stat.size);
            defer allocator.free(binary_data);

            _ = try extracted_file.readAll(binary_data);

            // Install it
            try installRawBinary(exe_path, binary_data);
            return;
        }
    }

    return error.BinaryNotFoundInArchive;
}

fn stripVersionPrefix(ver: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ver, "v")) {
        return ver[1..];
    }
    return ver;
}

const builtin = @import("builtin");

fn printHelp() void {
    const help_text =
        \\labelle - Command-line interface for labelle-engine projects
        \\
        \\USAGE:
        \\    labelle <command> [options] [path]
        \\
        \\COMMANDS:
        \\    init <name>     Create a new labelle project
        \\    generate        Generate project files from project.labelle
        \\    build           Build the project
        \\    run             Build and run the project
        \\    update          Update project to current CLI version
        \\    upgrade         Upgrade CLI to latest version
        \\    help            Show this help information
        \\    version         Show version information
        \\
        \\GLOBAL OPTIONS:
        \\    -h, --help      Show help for a command
        \\    -v, --version   Show version information
        \\
        \\EXAMPLES:
        \\    labelle init my-game              Create a new project
        \\    labelle generate                  Generate build files
        \\    labelle generate ./my-project     Generate for specific project
        \\    labelle build                     Build the project
        \\    labelle build --release ./game    Build in release mode
        \\    labelle run                       Build and run
        \\    labelle run --release ./game      Run in release mode
        \\    labelle update                    Update to current CLI version
        \\    labelle upgrade                   Upgrade CLI to latest version
        \\    labelle upgrade --check           Check for updates
        \\
        \\For more information on a command, use:
        \\    labelle <command> --help
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn printCommandHelp(command: Command) void {
    switch (command) {
        .init => {
            const help =
                \\labelle init - Create a new labelle project
                \\
                \\USAGE:
                \\    labelle init <project-name> [options]
                \\
                \\OPTIONS:
                \\    --backend <backend>         Graphics backend: raylib (default), sokol
                \\    --ecs-backend <backend>     ECS backend: zig_ecs (default), zflecs
                \\    --engine-path <path>        Use local engine path (for development)
                \\
                \\EXAMPLES:
                \\    labelle init my-game
                \\    labelle init my-game --backend sokol
                \\    labelle init my-game --ecs-backend zflecs
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .generate => {
            const help =
                \\labelle generate - Generate project files from project.labelle
                \\
                \\USAGE:
                \\    labelle generate [path] [options]
                \\
                \\OPTIONS:
                \\    --main-only                 Only regenerate main.zig
                \\    --engine-path <path>        Use local engine path (for development)
                \\    --no-fetch                  Skip fetching dependency hashes (faster, offline)
                \\
                \\DESCRIPTION:
                \\    Generates build.zig, build.zig.zon, and main.zig based on the
                \\    project.labelle configuration and folder contents (components,
                \\    prefabs, scripts, scenes).
                \\
                \\    By default, dependency hashes are fetched using 'zig fetch' to ensure
                \\    the generated build.zig.zon works immediately. Use --no-fetch to skip
                \\    this step for faster generation (hashes must be added manually).
                \\
                \\EXAMPLES:
                \\    labelle generate
                \\    labelle generate --main-only
                \\    labelle generate --no-fetch
                \\    labelle generate ./my-project
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .build => {
            const help =
                \\labelle build - Build the project
                \\
                \\USAGE:
                \\    labelle build [options] [path]
                \\
                \\ARGUMENTS:
                \\    path                        Path to project directory (default: current dir)
                \\
                \\OPTIONS:
                \\    -r, --release               Build in release mode
                \\    --backend <backend>         Override graphics backend
                \\    --ecs-backend <backend>     Override ECS backend
                \\
                \\EXAMPLES:
                \\    labelle build
                \\    labelle build --release
                \\    labelle build --release ./my-game
                \\    labelle build --backend sokol ./my-game
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .run => {
            const help =
                \\labelle run - Build and run the project
                \\
                \\USAGE:
                \\    labelle run [options] [path]
                \\
                \\ARGUMENTS:
                \\    path                        Path to project directory (default: current dir)
                \\
                \\OPTIONS:
                \\    -r, --release               Run in release mode
                \\    --backend <backend>         Override graphics backend
                \\    --ecs-backend <backend>     Override ECS backend
                \\
                \\EXAMPLES:
                \\    labelle run
                \\    labelle run --release
                \\    labelle run --release ./my-game
                \\    labelle run --backend sokol ./my-game
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .update => {
            const help =
                \\labelle update - Update project to current CLI version
                \\
                \\USAGE:
                \\    labelle update [path]
                \\
                \\ARGUMENTS:
                \\    path                        Path to project directory (default: current dir)
                \\
                \\OPTIONS:
                \\    --engine-path <path>        Use local engine path (for development)
                \\
                \\DESCRIPTION:
                \\    Updates the project's engine dependency to match the current CLI version.
                \\    This command:
                \\      - Clears cache directories (zig-cache, .zig-cache, zig-out)
                \\      - Regenerates build.zig.zon with updated fingerprint
                \\      - Regenerates build.zig and main.zig
                \\
                \\EXAMPLES:
                \\    labelle update
                \\    labelle update ./my-game
                \\    labelle update --engine-path ../labelle-engine
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .upgrade => {
            const help =
                \\labelle upgrade - Upgrade CLI to latest version
                \\
                \\USAGE:
                \\    labelle upgrade [options]
                \\
                \\OPTIONS:
                \\    -c, --check                 Check for updates without installing
                \\    --version <version>         Upgrade to specific version (e.g., 0.21.0)
                \\    -f, --force                 Force reinstall even if already on latest
                \\
                \\DESCRIPTION:
                \\    Downloads and installs the latest version of the labelle CLI from
                \\    GitHub releases. The current executable is replaced with the new version.
                \\
                \\    On some systems, you may need elevated privileges (sudo) to replace
                \\    the executable.
                \\
                \\EXAMPLES:
                \\    labelle upgrade                   Upgrade to latest version
                \\    labelle upgrade --check           Check for updates without installing
                \\    labelle upgrade --version 0.21.0  Upgrade to specific version
                \\    labelle upgrade --force           Force reinstall current version
                \\
            ;
            std.debug.print("{s}", .{help});
        },
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn printVersion() void {
    std.debug.print("labelle {s}\n", .{version});
}
