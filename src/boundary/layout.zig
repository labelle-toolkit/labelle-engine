//! Layout fingerprint for types that cross an independently compiled
//! library boundary (labelle-engine#923 prototype).
//!
//! Zig does not guarantee the field order / padding of an auto-layout
//! struct between two compilation units. In practice the same compiler,
//! source, target and CPU features give the same layout, but nothing
//! enforces it. Both sides of the boundary compute this hash at comptime
//! and the caller passes its value through the C ABI; the library refuses
//! to write the value when the two disagree, so a mismatch is a load error
//! instead of memory corruption.
const std = @import("std");

pub fn fingerprint(comptime T: type) u64 {
    @setEvalBranchQuota(200_000);
    var h = std.hash.Fnv1a_64.init();
    hashType(&h, T, 0);
    return h.final();
}

fn hashInt(h: *std.hash.Fnv1a_64, v: u64) void {
    h.update(std.mem.asBytes(&v));
}

fn hashType(comptime h: *std.hash.Fnv1a_64, comptime T: type, comptime depth: u32) void {
    hashInt(h, @sizeOf(T));
    hashInt(h, @alignOf(T));
    if (depth > 8) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            hashInt(h, s.fields.len);
            for (s.fields) |f| {
                if (f.is_comptime) continue;
                h.update(f.name);
                hashInt(h, @offsetOf(T, f.name));
                hashType(h, f.type, depth + 1);
            }
        },
        .pointer => |p| {
            hashInt(h, @intFromEnum(p.size));
            switch (@typeInfo(p.child)) {
                .@"fn", .@"opaque" => {},
                else => hashType(h, p.child, depth + 1),
            }
        },
        .optional => |o| hashType(h, o.child, depth + 1),
        .array => |a| {
            hashInt(h, a.len);
            hashType(h, a.child, depth + 1);
        },
        .@"enum" => |e| {
            hashType(h, e.tag_type, depth + 1);
            for (e.fields) |f| {
                h.update(f.name);
                hashInt(h, @as(u64, @truncate(@as(u128, @bitCast(@as(i128, f.value))))));
            }
        },
        .@"union" => |u| {
            for (u.fields) |f| {
                h.update(f.name);
                hashType(h, f.type, depth + 1);
            }
        },
        else => {},
    }
}
