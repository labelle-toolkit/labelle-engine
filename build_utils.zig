const std = @import("std");

/// Adds the labelle CLI executable to the build.
/// This is shared between build.zig and build_cli.zig to avoid duplication.
pub fn addCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zts: *std.Build.Module,
    build_zon: *std.Build.Module,
) *std.Build.Step.Compile {
    const cli_exe = b.addExecutable(.{
        .name = "labelle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts", .module = zts },
                .{ .name = "build_zon", .module = build_zon },
            },
        }),
    });

    b.installArtifact(cli_exe);
    return cli_exe;
}
