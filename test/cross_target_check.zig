//! #899: root of `zig build check-socket-targets`. Built (not linked, never
//! executed) for targets the host does not run. `main` takes the address of
//! every POSIX socket shim and of `screenshot_request.nowNs`, which makes Zig
//! analyze their bodies — and the target-dependent `std.c` constants they
//! use — for that target.

const std = @import("std");
const socket = @import("preview_socket");
const screenshot_request = @import("screenshot_request");

pub fn main() void {
    std.mem.doNotOptimizeAway(&socket.socketWrite);
    std.mem.doNotOptimizeAway(&socket.socketRead);
    std.mem.doNotOptimizeAway(&socket.socketClose);
    std.mem.doNotOptimizeAway(&socket.setNonBlocking);
    std.mem.doNotOptimizeAway(&socket.restoreBlocking);
    std.mem.doNotOptimizeAway(&socket.wouldBlock);
    std.mem.doNotOptimizeAway(&screenshot_request.nowNs);
}
