const std = @import("std");

// =============================================================================
// Fingerprint Detection
// =============================================================================

/// Run zig build and parse the suggested fingerprint from the error output
pub fn detectFingerprint(allocator: std.mem.Allocator, project_path: []const u8, build_file: []const u8) !u64 {
    _ = build_file; // No longer needed - always "build.zig"

    // Run zig build in the target directory
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
    _ = child.wait() catch {};
    const stderr_output = stderr_buf.items;

    // Parse fingerprint from error message like:
    // "missing top-level 'fingerprint' field; suggested value: 0xbc20e1ab89c1b519"
    // or "invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0xbc20e1ab89c1b519"
    const fingerprint = parseFingerprint(stderr_output) orelse {
        // If we can't parse it, return a default (this shouldn't happen)
        std.debug.print("Failed to parse fingerprint from output:\n{s}\n", .{stderr_output});
        return error.FingerprintNotFound;
    };

    return fingerprint;
}

/// Parse fingerprint value from zig build error output
pub fn parseFingerprint(output: []const u8) ?u64 {
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
