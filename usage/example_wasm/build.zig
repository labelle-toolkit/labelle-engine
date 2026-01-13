const std = @import("std");

pub const Backend = enum { raylib, sokol, sdl };
pub const EcsBackend = enum { zig_ecs, zflecs };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend: Backend = .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend") orelse .zig_ecs;

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .physics = true,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Check if targeting emscripten (WASM)
    const is_wasm = target.result.os.tag == .emscripten;

    if (is_wasm) {
        // Get raylib dependency for emsdk
        const labelle_gfx_dep = engine_dep.builder.dependency("labelle-gfx", .{
            .target = target,
            .optimize = optimize,
        });
        const raylib_zig = @import("raylib_zig");
        const emsdk = raylib_zig.emsdk;

        // Get raylib_zig dependency and raylib artifact
        const raylib_zig_dep = labelle_gfx_dep.builder.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
        });
        const raylib_artifact = raylib_zig_dep.artifact("raylib");

        // Get the actual raylib dependency (raylib_zig depends on raylib)
        const raylib_dep = raylib_zig_dep.builder.dependency("raylib", .{});

        // Create WASM library
        const wasm = b.addLibrary(.{
            .name = "example_wasm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_mod },
                },
            }),
        });

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{
            .optimize = optimize,
            .asyncify = true,
        });
        const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{
            .optimize = optimize,
        });

        // Get the shell.html path from raylib_zig's internal raylib dependency
        const shell_path = raylib_dep.path("src/shell.html");

        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = shell_path,
            .install_dir = install_dir,
        });

        const wasm_step = b.step("wasm", "Build for WebAssembly");
        wasm_step.dependOn(emcc_step);

        // Add emrun step to serve in browser
        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{"example_wasm"});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );
        emrun_step.dependOn(emcc_step);

        const serve_step = b.step("serve", "Build and serve in browser");
        serve_step.dependOn(emrun_step);
    } else {
        // Native build
        const exe = b.addExecutable(.{
            .name = "example_wasm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_mod },
                },
            }),
        });

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the bouncing ball demo");
        run_step.dependOn(&run_cmd.step);
    }
}
