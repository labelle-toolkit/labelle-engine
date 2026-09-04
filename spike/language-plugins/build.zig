//! Spike build: Zig host + system Lua 5.4 (static) + Rust staticlib.
//! macOS/homebrew POC — paths overridable via -Dlua-lib=... .
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lua_lib = b.option([]const u8, "lua-lib", "path to liblua static archive") orelse
        "/opt/homebrew/lib/liblua.a";

    const exe = b.addExecutable(.{
        .name = "lang-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addObjectFile(.{ .cwd_relative = lua_lib });

    // Rust staticlib: cargo build, then link the archive.
    const cargo = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--quiet",
        "--manifest-path",
    });
    cargo.addFileArg(b.path("rust/Cargo.toml"));
    exe.step.dependOn(&cargo.step);
    exe.root_module.addObjectFile(b.path("rust/target/release/liblabelle_rust_script.a"));

    // Crystal object: cross-compile to a .o, then `ld -r` with an
    // exported-symbols list to LOCALIZE the object's own `main` (Crystal
    // has no --no-main; the script exports `crystal_script_boot` — GC.init
    // + Crystal.main_user_code — as the embed seam instead).
    const crystal = b.addSystemCommand(&.{
        "crystal", "build", "--cross-compile",
        "--target", "aarch64-apple-darwin",
        "crystal/script.cr", "-o", "crystal/crystal_script",
    });
    const localize = b.addSystemCommand(&.{
        "ld", "-r", "crystal/crystal_script.o",
        "-o", "crystal/crystal_script_lib.o",
        "-exported_symbols_list", "crystal/exported_symbols.txt",
    });
    localize.step.dependOn(&crystal.step);
    exe.step.dependOn(&localize.step);
    exe.root_module.addObjectFile(b.path("crystal/crystal_script_lib.o"));
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.linkSystemLibrary("gc", .{});
    exe.root_module.linkSystemLibrary("iconv", .{});

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "run the spike").dependOn(&run.step);
}
