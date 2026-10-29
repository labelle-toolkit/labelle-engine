const std = @import("std");
pub const panic = std.debug.no_panic;
const settings = @import("settings");
const Codec = struct {
    pub fn decode(_: []const u8) u8 {
        return 0;
    }
    pub fn encode(_: u8, buf: []u8) ![]const u8 {
        buf[0] = '0';
        return buf[0..1];
    }
};
// Compile the public lifecycle without a platform test runner (which cannot
// run on Emscripten or Android from a desktop host).
export fn settings_compile_check(store: *const settings.Store) void {
    var buf: [64]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buf);
    var s = settings.Settings(u8, Codec, 8).init(allocator.allocator(), "setting", 0);
    defer s.deinit();
    s.set(2);
    s.saveIfChanged();
    s.pump(store.*) catch {};
    s.disable();
    _ = s.ready();
    _ = s.get();
}
