//! Lazy-init process-wide Io for engine code that historically used
//! std.fs.cwd() (removed in 0.16). Mirrors the assembler/cli pattern.
const std = @import("std");

var _threaded: std.Io.Threaded = undefined;
var _io: std.Io = undefined;
var _initialized: bool = false;

pub fn io() std.Io {
    if (!_initialized) {
        _threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _io = _threaded.io();
        _initialized = true;
    }
    return _io;
}
