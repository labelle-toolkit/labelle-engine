//! Public surface of `src/assets/`.
//!
//! Re-exports the catalog, loader vtable shapes, and worker message
//! types so that `engine.AssetCatalog` and friends can be reached
//! through a single import path. Concrete loaders (image, audio,
//! font) are intentionally *not* re-exported — the catalog resolves
//! them internally via `LoaderKind`.

const catalog_mod = @import("catalog.zig");
const loader_mod = @import("loader.zig");
const worker_mod = @import("worker.zig");

pub const AssetCatalog = catalog_mod.AssetCatalog;
pub const AssetEntry = catalog_mod.AssetEntry;
pub const AssetState = catalog_mod.AssetState;

pub const LoaderKind = loader_mod.LoaderKind;
pub const DecodedPayload = loader_mod.DecodedPayload;
pub const AssetLoaderVTable = loader_mod.AssetLoaderVTable;

pub const WorkRequest = worker_mod.WorkRequest;
pub const WorkResult = worker_mod.WorkResult;

test {
    // Pull every file in the module tree into the test binary so
    // `zig build test` exercises the catalog test blocks.
    _ = catalog_mod;
    _ = loader_mod;
    _ = worker_mod;
    _ = @import("loaders/image.zig");
    _ = @import("loaders/audio.zig");
    _ = @import("loaders/font.zig");
}
