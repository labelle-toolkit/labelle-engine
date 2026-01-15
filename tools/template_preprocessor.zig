// Template Preprocessor
//
// Expands `.include` directives in template files by inlining partial content.
// Run this tool when partials change to regenerate the full template files.
//
// Usage:
//   zig build run-template-preprocessor
//
// Or directly:
//   zig run tools/template_preprocessor.zig -- tools/templates/src/main_raylib.txt
//
// Directives:
//   .include partials/foo.txt  - Inlines the content of partials/foo.txt

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "--all")) {
        // Process all template files
        try processAllTemplates(allocator);
    } else {
        // Process single file
        try processTemplate(allocator, command);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Template Preprocessor - Expands .include directives
        \\
        \\Usage:
        \\  template_preprocessor <template_file>   Process single template
        \\  template_preprocessor --all             Process all templates
        \\  template_preprocessor --help            Show this help
        \\
        \\The preprocessor reads templates from templates/src/ and writes
        \\expanded templates to templates/ for embedding.
        \\
    , .{});
}

fn processAllTemplates(allocator: std.mem.Allocator) !void {
    const templates = [_][]const u8{
        "main_raylib.txt",
        "main_sdl.txt",
        "main_sokol.txt",
        "main_sokol_ios.txt",
        "main_sokol_android.txt",
        "main_wasm.txt",
        "main_bgfx.txt",
        "main_wgpu_native.txt",
    };

    for (templates) |template| {
        const src_path = try std.fmt.allocPrint(allocator, "tools/templates/src/{s}", .{template});
        defer allocator.free(src_path);

        // Check if source file exists
        std.fs.cwd().access(src_path, .{}) catch {
            // Source doesn't exist yet, skip
            std.debug.print("Skipping {s} (no source file)\n", .{template});
            continue;
        };

        std.debug.print("Processing {s}...\n", .{template});
        try processTemplate(allocator, src_path);
    }

    std.debug.print("\nDone! Templates updated.\n", .{});
}

fn processTemplate(allocator: std.mem.Allocator, input_path: []const u8) !void {
    // Read input file
    const input = std.fs.cwd().readFileAlloc(allocator, input_path, 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ input_path, err });
        return err;
    };
    defer allocator.free(input);

    // Get base directory for resolving includes
    const base_dir = std.fs.path.dirname(input_path) orelse ".";

    // Process includes
    const output = try expandIncludes(allocator, input, base_dir);
    defer allocator.free(output);

    // Determine output path (templates/src/foo.txt -> templates/foo.txt)
    const output_path = try determineOutputPath(allocator, input_path);
    defer allocator.free(output_path);

    // Write output
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output);

    std.debug.print("  Wrote {s}\n", .{output_path});
}

fn determineOutputPath(allocator: std.mem.Allocator, input_path: []const u8) ![]const u8 {
    // If path contains /src/, remove that component
    if (std.mem.indexOf(u8, input_path, "/src/")) |idx| {
        const before = input_path[0..idx];
        const after = input_path[idx + 4 ..]; // Skip "/src"
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ before, after });
    }
    // Otherwise append .out
    return std.fmt.allocPrint(allocator, "{s}.out", .{input_path});
}

fn expandIncludes(allocator: std.mem.Allocator, content: []const u8, base_dir: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;

    while (lines.next()) |line| {
        // Add newline before all lines except the first
        if (!first_line) {
            try result.append(allocator, '\n');
        }
        first_line = false;

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for .include directive
        if (std.mem.startsWith(u8, trimmed, ".include ")) {
            const include_path = std.mem.trim(u8, trimmed[9..], " \t\r");

            // Resolve path relative to base directory
            const full_path = try std.fs.path.join(allocator, &.{ base_dir, include_path });
            defer allocator.free(full_path);

            // Read and expand the included file (recursively)
            const included_content = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch |err| {
                std.debug.print("Error reading include {s}: {}\n", .{ full_path, err });
                return err;
            };
            defer allocator.free(included_content);

            // Get the include file's directory for nested includes
            const include_dir = std.fs.path.dirname(full_path) orelse base_dir;

            const expanded = try expandIncludes(allocator, included_content, include_dir);
            defer allocator.free(expanded);

            // Append included content (without trailing newline if present)
            const to_append = if (expanded.len > 0 and expanded[expanded.len - 1] == '\n')
                expanded[0 .. expanded.len - 1]
            else
                expanded;
            try result.appendSlice(allocator, to_append);
        } else {
            // Regular line, append as-is
            try result.appendSlice(allocator, line);
        }
    }

    return result.toOwnedSlice(allocator);
}
