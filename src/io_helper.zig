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
// std.Thread.Mutex was removed in Zig 0.16. std.Io.Mutex requires an
// Io param to lock/unlock, but here we're guarding Io's own init —
// chicken-and-egg. std.atomic.Mutex is the right primitive: a one-shot
// init runs once per process, contention is brief, spin is fine.
var _init_lock: std.atomic.Mutex = .unlocked;

pub fn io() std.Io {
    if (is_wasm_emscripten) {
        return std.Io.failing;
    }
    // Inside a test binary, reuse the test runner's `std.testing.io_instance`
    // rather than spinning up a second `Io.Threaded` pool. This keeps engine
    // codepaths that hit `io_helper.io()` (e.g. `loadScene` ->
    // `prefab_cache.scanDir`) on the same pool the test-side `std.testing.io`
    // calls use, sidestepping a second `sigaction(.IO, ...)` install and the
    // non-atomic lazy-init race that was sitting in this file regardless.
    // The CI hang investigated under #583 turned out to be unrelated to the
    // dual-pool concern (the zspec v0.9.1 runner never initialized
    // `std.testing.io_instance`, so the first `std.testing.io.*` call
    // deadlocked on an `0xaaaaaaaa` mutex); the upgrade to v0.9.2 fixes it.
    // This shared-pool path remains as defence-in-depth.
    if (builtin.is_test) {
        return std.testing.io_instance.io();
    }
    if (@atomicLoad(bool, &_initialized, .acquire)) return _io;
    while (!_init_lock.tryLock()) {}
    defer _init_lock.unlock();
    if (!_initialized) {
        _threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _io = _threaded.io();
        @atomicStore(bool, &_initialized, true, .release);
    }
    return _io;
}
