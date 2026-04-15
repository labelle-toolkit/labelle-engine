//! Placeholder image loader vtable.
//!
//! Every method is a stub: `decode` and `upload` return
//! `error.NotImplemented`, `drop` and `free` are no-ops. The real
//! implementation — backed by `gfx.decodeImage` / `gfx.uploadTexture`
//! — lands in ticket #440. Until then this file exists so that the
//! catalog can resolve `LoaderKind.image` to a concrete vtable
//! pointer at registration time.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loader = @import("../loader.zig");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;
const AssetEntry = loader.AssetEntry;

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
