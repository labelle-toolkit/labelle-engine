//! #899: root of `zig build check-ios`. Built for `aarch64-ios-simulator`
//! and never run. `main` takes the address of every POSIX shim, which makes
//! Zig analyze their bodies and the comptime constant asserts in
//! `src/preview/socket.zig` for an Apple mobile target. A non-Darwin branch
//! leaking onto iOS then fails the build. With `-Dios-sdk` the executable is
//! also linked, which catches a wrong errno symbol.
//!
//! This is an executable, not a `test` binary, with stack tracing, the
//! segfault handler and the full panic handler switched off. The test runner
//! and those handlers pull in std.debug's Mach-O `SelfInfo`, which needs
//! `_dyld_get_image_header_containing_address`, and the iOS simulator SDK
//! does not export that symbol.

const std = @import("std");
const socket = @import("preview_socket");

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

pub fn main() void {
    std.mem.doNotOptimizeAway(&socket.socketWrite);
    std.mem.doNotOptimizeAway(&socket.socketRead);
    std.mem.doNotOptimizeAway(&socket.socketClose);
    std.mem.doNotOptimizeAway(&socket.setNonBlocking);
    std.mem.doNotOptimizeAway(&socket.restoreBlocking);
    std.mem.doNotOptimizeAway(&socket.wouldBlock);
}
