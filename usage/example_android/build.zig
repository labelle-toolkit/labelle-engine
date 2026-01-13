const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum { sokol };
pub const EcsBackend = enum { zig_ecs, zflecs };

// Android SDK configuration - adjust these to match your installation
const ANDROID_API_VERSION = "34";
const ANDROID_BUILD_TOOLS_VERSION = "34.0.0";
const ANDROID_NDK_VERSION = "26.1.10909125";

const APP_NAME = "BouncingBall";
const BUNDLE_ID = "com.labelle.bouncingball";

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend") orelse .zig_ecs;

    // Android target: aarch64-linux-android
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    // Native target for tools
    const native_target = b.standardTargetOptions(.{});

    // =========================================================================
    // Configure NDK paths first (needed for sokol configuration)
    // =========================================================================
    const android_home = std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME") catch {
        std.log.err("ANDROID_HOME environment variable not set", .{});
        return;
    };

    const ndk_path = try std.fs.path.join(b.allocator, &.{ android_home, "ndk", ANDROID_NDK_VERSION });

    // Detect host OS for NDK toolchain
    const host_tag: []const u8 = switch (builtin.os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @panic("Unsupported host OS for Android NDK"),
    };

    const sysroot = try std.fs.path.join(b.allocator, &.{ ndk_path, "toolchains", "llvm", "prebuilt", host_tag, "sysroot" });
    const arch_inc_path = try std.fs.path.join(b.allocator, &.{ sysroot, "usr", "include", "aarch64-linux-android" });
    const inc_path = try std.fs.path.join(b.allocator, &.{ sysroot, "usr", "include" });
    const lib_path = try std.fs.path.join(b.allocator, &.{ sysroot, "usr", "lib", "aarch64-linux-android", ANDROID_API_VERSION });

    // =========================================================================
    // Get labelle-engine dependency
    // =========================================================================
    const engine_dep = b.dependency("labelle-engine", .{
        .target = android_target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = ecs_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get sokol dependency for Android support
    const sokol_dep = engine_dep.builder.dependency("sokol", .{
        .target = android_target,
        .optimize = optimize,
        .gles3 = true, // Force GLES3 for Android
        .dont_link_system_libs = true, // We handle NDK libs manually
    });

    // Configure sokol_clib with NDK paths
    const sokol_clib = sokol_dep.artifact("sokol_clib");
    sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = arch_inc_path });
    sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
    sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

    // =========================================================================
    // Create Android shared library
    // =========================================================================
    const android_lib = b.addLibrary(.{
        .name = APP_NAME,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = android_target,
            .optimize = optimize,
            .link_libc = true, // Use NDK libc via custom config
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
            },
        }),
    });

    // Set custom libc for Android NDK
    android_lib.setLibCFile(b.path("android_libc.conf"));

    // Set sysroot for NDK toolchain
    android_lib.root_module.addSystemIncludePath(.{ .cwd_relative = arch_inc_path });
    android_lib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });

    // Link sokol for Android
    android_lib.root_module.linkLibrary(sokol_dep.artifact("sokol_clib"));

    // Add library path for linking
    android_lib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

    // Link Android system libraries
    android_lib.root_module.linkSystemLibrary("GLESv3", .{});
    android_lib.root_module.linkSystemLibrary("EGL", .{});
    android_lib.root_module.linkSystemLibrary("android", .{});
    android_lib.root_module.linkSystemLibrary("log", .{});
    android_lib.root_module.linkSystemLibrary("aaudio", .{}); // For sokol_audio

    // Install the shared library (to zig-out/lib/)
    const install_lib = b.addInstallArtifact(android_lib, .{});

    // =========================================================================
    // APK Building Steps
    // =========================================================================

    // Step 1: Generate AndroidManifest.xml
    const manifest_step = b.addWriteFiles();
    _ = manifest_step.add("AndroidManifest.xml", generateManifest());

    // Step 2: Create keystore (if not exists)
    const keystore_step = CreateKeystoreStep.create(b);

    // Step 3: Build APK using bundletool
    const apk_step = b.step("apk", "Build Android APK");
    apk_step.dependOn(&install_lib.step);
    apk_step.dependOn(&manifest_step.step);
    apk_step.dependOn(&keystore_step.step);

    // Add info about manual APK building
    const info_step = b.addSystemCommand(&.{
        "echo",
        \\
        \\=== Android Build Complete ===
        \\
        \\Shared library built to: zig-out/lib/libBouncingBall.so
        \\
        \\To create an APK manually:
        \\1. Create an Android Studio project or use aapt2/bundletool
        \\2. Copy the .so file to app/src/main/jniLibs/arm64-v8a/
        \\3. Build the APK from Android Studio
        \\
        \\Or use bundletool with the generated manifest.
        \\
    });
    apk_step.dependOn(&info_step.step);

    // Default step builds the shared library
    const android_step = b.step("android", "Build for Android");
    android_step.dependOn(&install_lib.step);

    // Also support native build for testing
    const native_exe = b.addExecutable(.{
        .name = "example_android_native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = b.dependency("labelle-engine", .{
                    .target = native_target,
                    .optimize = optimize,
                    .backend = .sokol,
                    .ecs_backend = ecs_backend,
                }).module("labelle-engine") },
            },
        }),
    });

    b.installArtifact(native_exe);

    const run_cmd = b.addRunArtifact(native_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run native version for testing");
    run_step.dependOn(&run_cmd.step);
}

fn generateManifest() []const u8 {
    return
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="
    ++ BUNDLE_ID ++
        \\"
        \\    android:versionCode="1"
        \\    android:versionName="1.0">
        \\
        \\    <uses-sdk
        \\        android:minSdkVersion="
    ++ ANDROID_API_VERSION ++
        \\"
        \\        android:targetSdkVersion="
    ++ ANDROID_API_VERSION ++
        \\" />
        \\
        \\    <uses-feature android:glEsVersion="0x00030000" android:required="true" />
        \\
        \\    <application
        \\        android:allowBackup="false"
        \\        android:fullBackupContent="false"
        \\        android:icon="@mipmap/ic_launcher"
        \\        android:label="Bouncing Ball"
        \\        android:hasCode="false">
        \\
        \\        <activity
        \\            android:name="android.app.NativeActivity"
        \\            android:label="Bouncing Ball"
        \\            android:configChanges="orientation|screenSize|screenLayout|keyboardHidden"
        \\            android:exported="true">
        \\
        \\            <meta-data
        \\                android:name="android.app.lib_name"
        \\                android:value="
    ++ APP_NAME ++
        \\" />
        \\
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\        </activity>
        \\    </application>
        \\</manifest>
    ;
}

const CreateKeystoreStep = struct {
    step: std.Build.Step,
    b: *std.Build,

    pub fn create(b: *std.Build) *CreateKeystoreStep {
        const self = b.allocator.create(CreateKeystoreStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "create-keystore",
                .owner = b,
                .makeFn = make,
            }),
            .b = b,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *CreateKeystoreStep = @fieldParentPtr("step", step);
        const keystore_path = self.b.pathFromRoot("debug.keystore");

        // Check if keystore already exists
        std.fs.cwd().access(keystore_path, .{}) catch {
            // Create keystore using keytool
            std.log.info("Creating debug keystore...", .{});
            var child = std.process.Child.init(&.{
                "keytool",
                "-genkeypair",
                "-keystore",
                keystore_path,
                "-alias",
                "androiddebugkey",
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "10000",
                "-storepass",
                "android",
                "-keypass",
                "android",
                "-dname",
                "CN=Debug,O=Debug,C=US",
            }, self.b.allocator);
            child.spawn() catch |err| {
                std.log.warn("Could not create keystore (keytool not found?): {}", .{err});
                return;
            };
            _ = child.wait() catch {};
        };
    }
};
