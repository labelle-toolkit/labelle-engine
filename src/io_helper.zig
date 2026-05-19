//! Lazy-init process-wide Io for engine code that historically used
//! std.fs.cwd() (removed in 0.16). Mirrors the assembler/cli pattern.
const std = @import("std");
const builtin = @import("builtin");

// wasm32-emscripten gate (labelle-assembler#141): `std.Io.Threaded`
// pulls broken posix wrappers (`childWaitPosix` references a u32 where
// an enum is expected — ziglang/zig#31849). On emscripten file I/O
// historically went through emscripten's MEMFS via `std.fs.cwd()` —
// in 0.16 the path lives behind `std.Io.Dir.cwd()` which requires an
// `Io` parameter. We hand it `std.Io.failing` to keep the type system
// happy without ever instantiating `Threaded` (whose vtable assignment
// would compile the broken posix wrappers). Asset-load codepaths that
// hit the FS will surface a clean `Failed` error rather than a compile
// failure; standalone preview / scene assets need to come through
// preloaded buffers on wasm anyway (#141 follow-up).
const is_wasm_emscripten = builtin.target.os.tag == .emscripten;

var _threaded: if (is_wasm_emscripten) void else std.Io.Threaded = if (is_wasm_emscripten) {} else undefined;
var _io: std.Io = undefined;
var _initialized: bool = false;

pub fn io() std.Io {
    if (is_wasm_emscripten) {
        return std.Io.failing;
    }
    if (!_initialized) {
        _threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _io = _threaded.io();
        _initialized = true;
    }
    return _io;
}
