//! AssetCatalog facade.
//!
//! The catalog implementation and its test suites were split out of
//! this file into `catalog/` to keep every source file under 1000
//! lines (see `catalog/engine.zig` for the full design notes and
//! invariants). This module is a thin re-export of the public surface
//! so existing import paths (`@import("catalog.zig").AssetCatalog`,
//! the `engine.AssetCatalog` re-export in `mod.zig`, and the
//! Game/asset mixins) keep working unchanged.
//!
//! Layout:
//!   * `catalog/engine.zig`         — `AssetCatalog` + constants + helpers
//!   * `catalog/test_support.zig`   — shared test fixtures (mock backend, …)
//!   * `catalog/tests_lifecycle.zig`— register/acquire/release/query tests
//!   * `catalog/tests_pump.zig`     — pump() state-machine tests (#442)
//!   * `catalog/tests_release.zig`  — release() backend-free tests (#446)

const engine = @import("catalog/engine.zig");

pub const LoaderKind = engine.LoaderKind;
pub const DecodedPayload = engine.DecodedPayload;
pub const UploadedResource = engine.UploadedResource;
pub const Texture = engine.Texture;
pub const AssetLoaderVTable = engine.AssetLoaderVTable;
pub const AssetState = engine.AssetState;
pub const AssetEntry = engine.AssetEntry;
pub const WorkRequest = engine.WorkRequest;
pub const WorkResult = engine.WorkResult;

pub const UPLOAD_BUDGET_PER_FRAME = engine.UPLOAD_BUDGET_PER_FRAME;
pub const NUM_WORKERS = engine.NUM_WORKERS;

pub const AssetCatalog = engine.AssetCatalog;

test {
    // Pull the split-out test files into the test binary. `mod.zig`'s
    // root `test` block references this module, which only discovers
    // in-source `test` blocks reachable from here — so the sibling
    // test files must be referenced explicitly.
    _ = @import("catalog/tests_lifecycle.zig");
    _ = @import("catalog/tests_pump.zig");
    _ = @import("catalog/tests_release.zig");
}
