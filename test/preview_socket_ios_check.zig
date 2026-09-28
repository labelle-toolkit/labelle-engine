//! #899: root of `zig build check-ios`. Compiled for
//! `aarch64-ios-simulator` only — never run. Referencing every POSIX shim
//! forces their bodies (and the comptime constant asserts in
//! `src/preview/socket.zig`) to be analyzed for an Apple mobile target, so a
//! non-Darwin branch leaking onto iOS fails the build. With `-Dios-sdk` the
//! binary is also linked, which catches a wrong errno symbol.

const socket = @import("preview_socket");

test "preview socket shims analyze for the target (#899)" {
    _ = &socket.socketWrite;
    _ = &socket.socketRead;
    _ = &socket.socketClose;
    _ = &socket.setNonBlocking;
    _ = &socket.restoreBlocking;
    _ = &socket.wouldBlock;
}
