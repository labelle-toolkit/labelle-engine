const std = @import("std");

// =============================================================================
// Name Sanitization & Utilities
// =============================================================================

/// Sanitize a project name to be a valid Zig identifier.
/// - Replaces hyphens with underscores
/// - Removes any invalid characters (only a-z, A-Z, 0-9, _ allowed)
/// - Prepends underscore if name starts with a digit
/// - Returns error if name is empty or becomes empty after sanitization
pub fn sanitizeZigIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return error.InvalidIdentifier;

    // Count valid characters and check if result starts with digit
    var valid_count: usize = 0;
    var starts_with_digit = false;
    var seen_valid_char = false; // Track if we've seen any valid output character
    for (name) |c| {
        if (isValidIdentifierChar(c)) {
            // Check if first valid character is a digit
            if (!seen_valid_char and std.ascii.isDigit(c)) {
                starts_with_digit = true;
            }
            seen_valid_char = true;
            valid_count += 1;
        } else if (c == '-') {
            // Hyphens become underscores - underscore is valid start
            seen_valid_char = true;
            valid_count += 1;
        }
        // Other characters are silently dropped
    }

    if (valid_count == 0) return error.InvalidIdentifier;

    // Allocate result (add 1 if we need to prepend underscore)
    const extra: usize = if (starts_with_digit) 1 else 0;
    var result = try allocator.alloc(u8, valid_count + extra);

    // Build result
    var idx: usize = 0;
    if (starts_with_digit) {
        result[0] = '_';
        idx = 1;
    }

    for (name) |c| {
        if (isValidIdentifierChar(c)) {
            result[idx] = c;
            idx += 1;
        } else if (c == '-') {
            result[idx] = '_';
            idx += 1;
        }
    }

    return result;
}

/// Check if character is valid in a Zig identifier (alphanumeric or underscore)
pub fn isValidIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Fetch package hash using zig fetch command
/// Returns the hash string or null if fetch fails
pub fn fetchPackageHash(allocator: std.mem.Allocator, url: []const u8) !?[]const u8 {
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

/// Result type for toPascalCase
pub const PascalCaseResult = struct { buf: [64]u8, len: usize };

/// Convert snake_case to PascalCase (returns stack-allocated buffer and length)
/// e.g., "task_workstation" -> "TaskWorkstation"
pub fn toPascalCase(name: []const u8) error{NameTooLong}!PascalCaseResult {
    if (name.len > 64) return error.NameTooLong;
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
