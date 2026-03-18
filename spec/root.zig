const zspec = @import("zspec");

pub const script_filtering_spec = @import("script_filtering_spec.zig");

test {
    zspec.runAll(@This());
}
