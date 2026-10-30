//! Game-unit side of the independently compiled TMX loader
//! (labelle-engine#923 PROTOTYPE).
//!
//! Opt-in on the compilation root, the same way as `labelle_hook_trace`:
//!
//! ```zig
//! pub const labelle_engine_rt_tmx = true;
//! ```
//!
//! and link the static library built from `src/boundary/tmx_rt.zig`. With
//! the declaration absent nothing here is referenced and the parser stays
//! in the game unit exactly as before.
const std = @import("std");
const root = @import("root");
const abi = @import("tmx_abi.zig");
const layout = @import("layout.zig");

pub const root_decl = "labelle_engine_rt_tmx";
pub const enabled: bool = @hasDecl(root, root_decl) and @field(root, root_decl);

/// `images` is `tilemap_runtime.ImageProvider` (duck-typed to avoid an
/// import cycle): `.context` + `.getFn(context, name) ?[]const u8`.
pub fn loadTileMap(comptime TileMap: type, tmx_bytes: []const u8, images: anytype) !TileMap {
    const Images = @TypeOf(images);
    const Tramp = struct {
        fn resolve(ctx: ?*anyopaque, name_ptr: [*]const u8, name_len: usize, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) bool {
            const p: *const Images = @ptrCast(@alignCast(ctx.?));
            const bytes = p.getFn(p.context, name_ptr[0..name_len]) orelse return false;
            out_ptr.* = bytes.ptr;
            out_len.* = bytes.len;
            return true;
        }
    };
    if (abi.Externs.labelle_rt_abi_version() != abi.abi_version) return error.EngineRtAbiMismatch;
    if (abi.Externs.labelle_rt_build_flags() != abi.buildFlags()) {
        std.log.err("engine rt boundary: build flags differ (lib 0x{x}, game 0x{x})", .{ abi.Externs.labelle_rt_build_flags(), abi.buildFlags() });
        return error.EngineRtAbiMismatch;
    }
    var map: TileMap = undefined;
    const status = abi.Externs.labelle_rt_tmx_load(
        tmx_bytes.ptr,
        tmx_bytes.len,
        @ptrCast(@constCast(&images)),
        Tramp.resolve,
        &map,
        @sizeOf(TileMap),
        comptime layout.fingerprint(TileMap),
    );
    switch (status) {
        .ok => {},
        .out_of_memory => return error.OutOfMemory,
        .abi_mismatch => return error.EngineRtAbiMismatch,
        else => {
            var n: usize = 0;
            const p = abi.Externs.labelle_rt_last_error(&n);
            std.log.err("tmx (engine rt boundary): {s}", .{p[0..n]});
            return error.TileMapLoadFailed;
        },
    }
    // The library allocated through ITS copy of `std.heap.c_allocator`;
    // never call back through that vtable (auto-callconv fn pointers from
    // another unit). This unit's c_allocator frees the same malloc heap.
    map.allocator = std.heap.c_allocator;
    return map;
}
