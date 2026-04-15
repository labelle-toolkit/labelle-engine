//! Placeholder audio loader vtable.
//!
//! Stub identical in shape to `loaders/image.zig`. Real `decodeAudio`
//! / `uploadAudio` arrives in ticket #441 (Phase 4 of the RFC).

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader = @import("../loader.zig");
const catalog = @import("../catalog.zig");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;
const AssetEntry = catalog.AssetEntry;

fn decode(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: Allocator,
) anyerror!DecodedPayload {
    _ = file_type;
    _ = data;
    _ = allocator;
    return error.NotImplemented;
}

fn upload(entry: *AssetEntry, decoded: DecodedPayload) anyerror!void {
    _ = entry;
    _ = decoded;
    return error.NotImplemented;
}

fn drop(allocator: Allocator, decoded: DecodedPayload) void {
    _ = allocator;
    _ = decoded;
}

fn free(entry: *AssetEntry) void {
    _ = entry;
}

pub const vtable: AssetLoaderVTable = .{
    .decode = decode,
    .upload = upload,
    .drop = drop,
    .free = free,
};
