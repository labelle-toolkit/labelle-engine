const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jsonc_module = b.addModule("jsonc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zspec = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run jsonc tests");

    // Inline tests in src/
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // zspec test files in test/
    const test_files = [_][]const u8{
        "test/parser_test.zig",
        "test/value_test.zig",
        "test/deserialize_test.zig",
        "test/scene_loader_test.zig",
        "test/hot_reload_test.zig",
    };

    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zspec", .module = zspec.module("zspec") },
                    .{ .name = "jsonc", .module = jsonc_module },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
