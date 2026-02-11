const std = @import("std");

// =============================================================================
// Version Management
// =============================================================================

/// Semantic version with major.minor.patch
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(str: []const u8) !Version {
        // Strip 'v' prefix if present
        const version_str = if (std.mem.startsWith(u8, str, "v")) str[1..] else str;

        var iter = std.mem.splitScalar(u8, version_str, '.');
        const major_str = iter.next() orelse return error.InvalidVersion;
        const minor_str = iter.next() orelse return error.InvalidVersion;
        const patch_str = iter.next() orelse return error.InvalidVersion;

        return Version{
            .major = try std.fmt.parseInt(u32, major_str, 10),
            .minor = try std.fmt.parseInt(u32, minor_str, 10),
            .patch = try std.fmt.parseInt(u32, patch_str, 10),
        };
    }

    pub fn format(self: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    pub fn lt(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }

    pub fn gte(self: Version, other: Version) bool {
        return !self.lt(other);
    }
};

/// Plugin compatibility metadata
pub const PluginCompatibility = struct {
    name: []const u8,
    min_version: Version,
    max_version: Version,
    reason: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginCompatibility) void {
        self.allocator.free(self.name);
        self.allocator.free(self.reason);
    }

    pub fn checkCompatibility(self: PluginCompatibility, engine_version: Version) CompatibilityResult {
        // Below minimum = incompatible
        if (engine_version.lt(self.min_version)) {
            return .incompatible;
        }

        // Within range = compatible
        if (engine_version.lt(self.max_version)) {
            return .compatible;
        }

        // Above maximum = untested (warning)
        return .untested;
    }
};

pub const CompatibilityResult = enum {
    compatible,
    incompatible,
    untested,
};

/// Read plugin compatibility metadata from .labelle-plugin file
pub fn readPluginCompatibility(allocator: std.mem.Allocator, project_path: []const u8, plugin_path: []const u8) !?PluginCompatibility {
    // Resolve project path to absolute first
    const abs_project_path = std.fs.cwd().realpathAlloc(allocator, project_path) catch {
        return null;
    };
    defer allocator.free(abs_project_path);

    // Now join plugin path (which is relative to project)
    const joined_path = try std.fs.path.join(allocator, &.{ abs_project_path, plugin_path });
    defer allocator.free(joined_path);

    // Resolve the final plugin path
    const full_plugin_path = std.fs.cwd().realpathAlloc(allocator, joined_path) catch {
        return null;
    };
    defer allocator.free(full_plugin_path);

    const metadata_path = try std.fs.path.join(allocator, &.{ full_plugin_path, ".labelle-plugin" });
    defer allocator.free(metadata_path);

    // Read the file
    const file = std.fs.cwd().openFile(metadata_path, .{}) catch {
        // No metadata file = no version checking
        return null;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse the metadata (simple key = "value" format)
    var name: ?[]const u8 = null;
    var min_version_str: ?[]const u8 = null;
    var max_version_str: ?[]const u8 = null;
    var reason: []const u8 = "No reason specified";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip comments and empty lines
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        // Parse key = "value" format
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value_part = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Extract value from quotes
            const value = if (std.mem.startsWith(u8, value_part, "\"")) blk: {
                if (std.mem.lastIndexOf(u8, value_part, "\"")) |end| {
                    if (end > 0) {
                        break :blk value_part[1..end];
                    }
                }
                break :blk value_part;
            } else value_part;

            if (std.mem.eql(u8, key, "name")) {
                name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "min_version")) {
                min_version_str = value;
            } else if (std.mem.eql(u8, key, "max_version")) {
                max_version_str = value;
            } else if (std.mem.eql(u8, key, "reason")) {
                reason = try allocator.dupe(u8, value);
            }
        }
    }

    // Require name and version info
    const plugin_name = name orelse return null;
    const min_ver_str = min_version_str orelse {
        allocator.free(plugin_name);
        if (!std.mem.eql(u8, reason, "No reason specified")) allocator.free(reason);
        return null;
    };
    const max_ver_str = max_version_str orelse {
        allocator.free(plugin_name);
        if (!std.mem.eql(u8, reason, "No reason specified")) allocator.free(reason);
        return null;
    };

    return PluginCompatibility{
        .name = plugin_name,
        .min_version = Version.parse(min_ver_str) catch {
            allocator.free(plugin_name);
            if (!std.mem.eql(u8, reason, "No reason specified")) allocator.free(reason);
            return null;
        },
        .max_version = Version.parse(max_ver_str) catch {
            allocator.free(plugin_name);
            if (!std.mem.eql(u8, reason, "No reason specified")) allocator.free(reason);
            return null;
        },
        .reason = reason,
        .allocator = allocator,
    };
}
