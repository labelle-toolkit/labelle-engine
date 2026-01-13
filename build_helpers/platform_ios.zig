//! iOS Platform Build Helpers
//!
//! Handles iOS-specific SDK paths and configurations for cross-compilation.
//! Workaround for Zig issues where getSdk() returns null for cross-compilation
//! and sysroot doesn't affect framework search paths.

const std = @import("std");

/// iOS SDK paths (comptime constants)
pub const Sdk = struct {
    pub const simulator_base = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk";
    pub const device_base = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk";

    // Simulator paths
    pub const simulator_include = simulator_base ++ "/usr/include";
    pub const simulator_lib = simulator_base ++ "/usr/lib";
    pub const simulator_frameworks = simulator_base ++ "/System/Library/Frameworks";
    pub const simulator_subframeworks = simulator_base ++ "/System/Library/SubFrameworks";

    // Device paths
    pub const device_include = device_base ++ "/usr/include";
    pub const device_lib = device_base ++ "/usr/lib";
    pub const device_frameworks = device_base ++ "/System/Library/Frameworks";
    pub const device_subframeworks = device_base ++ "/System/Library/SubFrameworks";
};

/// Add iOS SDK paths to a C library artifact (for headers and libraries)
pub fn addSdkPathsToArtifact(artifact: *std.Build.Step.Compile, target: std.Target) void {
    if (target.abi == .simulator) {
        artifact.root_module.addSystemIncludePath(.{ .cwd_relative = Sdk.simulator_include });
        artifact.root_module.addLibraryPath(.{ .cwd_relative = Sdk.simulator_lib });
    } else {
        artifact.root_module.addSystemIncludePath(.{ .cwd_relative = Sdk.device_include });
        artifact.root_module.addLibraryPath(.{ .cwd_relative = Sdk.device_lib });
    }
}

/// Add iOS SDK framework paths to a C library artifact (for Metal, UIKit, etc.)
pub fn addFrameworkPathsToArtifact(artifact: *std.Build.Step.Compile, target: std.Target) void {
    if (target.abi == .simulator) {
        artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = Sdk.simulator_frameworks });
        artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = Sdk.simulator_subframeworks });
    } else {
        artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = Sdk.device_frameworks });
        artifact.root_module.addSystemFrameworkPath(.{ .cwd_relative = Sdk.device_subframeworks });
    }
}

/// Add all iOS SDK paths (includes, libs, frameworks) to an artifact
pub fn addAllSdkPaths(artifact: *std.Build.Step.Compile, target: std.Target) void {
    addSdkPathsToArtifact(artifact, target);
    addFrameworkPathsToArtifact(artifact, target);
}

/// Configure sokol dependency for iOS
/// Adds framework and include paths needed for Metal backend
pub fn configureSokol(sokol_dep: *std.Build.Dependency, target: std.Target) void {
    const sokol_clib = sokol_dep.artifact("sokol_clib");
    addAllSdkPaths(sokol_clib, target);
}

/// Configure zflecs dependency for iOS
/// Adds include and library paths needed for C compilation
pub fn configureZflecs(zflecs_dep: *std.Build.Dependency, target: std.Target) void {
    const flecs_artifact = zflecs_dep.artifact("flecs");
    addSdkPathsToArtifact(flecs_artifact, target);
}

/// Configure Box2D dependency for iOS
/// Adds include paths and optionally disables SIMD for simulator
pub fn configureBox2d(
    box2d_dep: *std.Build.Dependency,
    target: std.Target,
    is_simulator: bool,
) void {
    const box2d_artifact = box2d_dep.artifact("box2d");

    // Disable SIMD on iOS simulator (ARM) - NEON intrinsics issues
    if (is_simulator and target.cpu.arch == .aarch64) {
        box2d_artifact.root_module.addCMacro("BOX2D_DISABLE_SIMD", "1");
    }

    // Add SDK paths for C headers
    addSdkPathsToArtifact(box2d_artifact, target);
}

/// Add iOS SDK include path to a module (for @cImport)
pub fn addModuleIncludePath(module: *std.Build.Module, target: std.Target) void {
    if (target.abi == .simulator) {
        module.addSystemIncludePath(.{ .cwd_relative = Sdk.simulator_include });
    } else {
        module.addSystemIncludePath(.{ .cwd_relative = Sdk.device_include });
    }
}
