//! Platform utilities for labelle-engine
//!
//! Provides platform-aware helpers for cross-platform compatibility.

const std = @import("std");
const builtin = @import("builtin");

/// Returns the default allocator for the current platform.
///
/// - WASM/Emscripten: Uses `c_allocator` (page_allocator doesn't work)
/// - Native platforms: Uses `page_allocator`
///
/// Use this instead of hardcoding an allocator when you need a simple
/// default allocator that works across all supported platforms.
pub fn getDefaultAllocator() std.mem.Allocator {
    return if (builtin.os.tag == .emscripten)
        std.heap.c_allocator
    else
        std.heap.page_allocator;
}
