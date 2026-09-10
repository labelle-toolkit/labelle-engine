/// Zero-based frame cue. The shared definition owns the name.
pub const Marker = struct {
    name: []const u8,
    frame: u8,
};
