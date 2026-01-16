const std = @import("std");
const builtin = @import("builtin");

pub const EcsBackend = enum { zig_ecs, zflecs };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend") orelse .zig_ecs;

    // Get labelle-engine dependency
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = ecs_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get labelle-physics dependency
    const physics_dep = b.dependency("labelle-physics", .{
        .target = target,
        .optimize = optimize,
    });
    const physics_mod = physics_dep.module("labelle-physics");

    // Create executable
    const exe = b.addExecutable(.{
        .name = "mobile_physics_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the physics test");
    run_step.dependOn(&run_cmd.step);

    // Test step (just builds to verify compilation)
    const test_step = b.step("test", "Build and verify compilation");
    test_step.dependOn(&exe.step);

    // =========================================================================
    // Android Build - Creates a shared library for Android NativeActivity
    // =========================================================================
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    // Use ReleaseSafe for Android builds (better performance than Debug)
    const android_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    // Android library directory (passed from CI via -Dandroid-lib-dir=...)
    const android_lib_dir = b.option([]const u8, "android-lib-dir", "Path to Android NDK libraries");

    // Get engine for Android target
    const android_engine_dep = b.dependency("labelle-engine", .{
        .target = android_target,
        .optimize = android_optimize,
        .backend = .sokol,
        .ecs_backend = ecs_backend,
    });
    const android_engine_mod = android_engine_dep.module("labelle-engine");

    // Get physics for Android target
    const android_physics_dep = b.dependency("labelle-physics", .{
        .target = android_target,
        .optimize = android_optimize,
    });
    const android_physics_mod = android_physics_dep.module("labelle-physics");

    // Create shared library for Android (NativeActivity loads .so files)
    const android_lib = b.addLibrary(.{
        .name = "mobile_physics_test",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = android_target,
            .optimize = android_optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = android_engine_mod },
                .{ .name = "labelle-physics", .module = android_physics_mod },
            },
        }),
    });

    // Add Android NDK library path if provided
    if (android_lib_dir) |lib_dir| {
        android_lib.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }

    // Link Android system libraries
    android_lib.linkSystemLibrary("android");
    android_lib.linkSystemLibrary("log");
    android_lib.linkSystemLibrary("EGL");
    android_lib.linkSystemLibrary("GLESv3");
    android_lib.linkLibC();

    const android_step = b.step("android", "Build shared library for Android");
    android_step.dependOn(&b.addInstallArtifact(android_lib, .{}).step);
}
