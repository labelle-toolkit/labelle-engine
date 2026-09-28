//! Compile-only ABI check against the actual backend bindings. Run command
//! documented in docs/persistent-blobs.md; no browser or emcc link is needed.
const std = @import("std");
// Match the generated wasm root: defaultPanic itself pulls in the broken
// Zig 0.16 emscripten Threaded vtable even when storage uses no file I/O.
pub const panic = std.debug.no_panic;
const storage = @import("storage");
const bindings = @import("storage-bindings");
var web: storage.Web(bindings) = .{ .namespace = "compile-check" };
var operation: ?storage.Operation = null;

export fn storage_begin_read() void {
    operation = web.store().begin(std.heap.page_allocator, .{ .read = .{ .name = "a.json", .max_bytes = 1024 } }) catch return;
}
export fn storage_poll() void {
    if (operation) |*op| {
        const result = op.poll() catch return;
        if (result) |r| r.deinit(std.heap.page_allocator);
    }
}
export fn storage_release() void {
    if (operation) |*op| op.deinit();
    operation = null;
}
