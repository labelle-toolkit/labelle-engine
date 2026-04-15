//! Asset worker request / result message types.
//!
//! This file declares **types only** — no thread, no SPSC ring
//! buffers, no decode loop. Ticket #439 adds the `std.Thread`
//! worker plus the bounded SPSC rings that the catalog will use to
//! hand off requests and drain results from `pump()`.
//!
//! The shapes are pinned here so that the catalog (#438), the legacy
//! shim (#443), and the future scene wiring (#444+) can all reference
//! them without waiting on the threading work to land.

const loader = @import("loader.zig");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;

/// Snapshot handed to the worker thread. Every field is borrowed —
/// `entry_name`, `file_type` and `bytes` all live for the program's
/// entire lifetime (see the `@embedFile` invariant on the catalog),
/// so the worker can read them without touching the catalog.
pub const WorkRequest = struct {
    entry_name: []const u8,
    vtable: *const AssetLoaderVTable,
    file_type: [:0]const u8,
    bytes: []const u8,
};

/// Worker → main message. Either `decoded` is set (success) or
/// `err` is set (failure); `pump()` discriminates and routes to
/// `loader.upload` / `loader.drop` accordingly. Lands in #442.
pub const WorkResult = struct {
    entry_name: []const u8,
    decoded: ?DecodedPayload,
    err: ?anyerror,
};
