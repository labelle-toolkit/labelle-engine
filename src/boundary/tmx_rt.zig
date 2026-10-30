//! Root of the independently compiled engine runtime library
//! (labelle-engine#923 PROTOTYPE). Build it as its OWN static library,
//! importing the same `tilemap` module the renderer uses, with the same
//! target, CPU features (atomics/bulk_memory when threaded), optimize mode
//! and `single_threaded` flag as the game. See `tmx_abi.zig`.
const std = @import("std");
const tilemap = @import("tilemap");
const abi = @import("tmx_abi.zig");
const layout = @import("layout.zig");

const TileMap = tilemap.TileMap;

// Zig 0.16: on the prototype's target the default panic handler / debug IO
// pull in std.Io.Threaded's broken posix wrappers (labelle-assembler#141).
// This unit has no backend template supplying `panic`, so it carries both
// halves: the same trap handler the backend template installs in the game.
pub const panic = std.debug.FullPanic(struct {
    fn handler(msg: []const u8, ret_addr: ?usize) noreturn {
        _ = msg;
        _ = ret_addr;
        @trap();
    }
}.handler);
pub const std_options_debug_io = std.Io.failing;

threadlocal var last_error: []const u8 = "";

export fn labelle_rt_abi_version() callconv(.c) u32 {
    return abi.abi_version;
}

export fn labelle_rt_build_flags() callconv(.c) u32 {
    return abi.buildFlags();
}

export fn labelle_rt_last_error(len: *usize) callconv(.c) [*]const u8 {
    len.* = last_error.len;
    return last_error.ptr;
}

const Bridge = struct {
    ctx: ?*anyopaque,
    resolve: abi.ResolveFn,

    fn call(context: ?*anyopaque, source: []const u8) ?[]const u8 {
        const self: *const Bridge = @ptrCast(@alignCast(context.?));
        var p: [*]const u8 = undefined;
        var n: usize = 0;
        if (!self.resolve(self.ctx, source.ptr, source.len, &p, &n)) return null;
        return p[0..n];
    }
};

export fn labelle_rt_tmx_load(
    content_ptr: [*]const u8,
    content_len: usize,
    resolver_ctx: ?*anyopaque,
    resolver: ?abi.ResolveFn,
    out: *anyopaque,
    out_size: usize,
    expected_layout: u64,
) callconv(.c) abi.Status {
    if (out_size != @sizeOf(TileMap) or expected_layout != comptime layout.fingerprint(TileMap)) {
        last_error = "AbiMismatch";
        return .abi_mismatch;
    }
    var bridge: Bridge = undefined;
    var options: tilemap.LoadOptions = .{ .read_external_from_filesystem = false };
    if (resolver) |r| {
        bridge = .{ .ctx = resolver_ctx, .resolve = r };
        options.tsx_resolver = .{ .context = &bridge, .resolveFn = Bridge.call };
    }
    const map = TileMap.loadFromMemoryWithOptions(std.heap.c_allocator, content_ptr[0..content_len], "", options) catch |err| {
        last_error = @errorName(err);
        return if (err == error.OutOfMemory) .out_of_memory else .parse_failed;
    };
    const dst: *TileMap = @ptrCast(@alignCast(out));
    dst.* = map;
    return .ok;
}
