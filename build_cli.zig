const std = @import("std");

/// Minimal build file for the labelle CLI executable only.
/// This avoids loading graphics dependencies (SDL2, raylib, etc.)
/// which are not needed for the CLI and may not be available on all platforms.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
    });
    const zts = zts_dep.module("zts");

    // Build.zig.zon module for version info
    const build_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Main CLI executable
    const cli_exe = b.addExecutable(.{
        .name = "labelle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts", .module = zts },
                .{ .name = "build_zon", .module = build_zon_mod },
            },
        }),
    });

    b.installArtifact(cli_exe);
}
