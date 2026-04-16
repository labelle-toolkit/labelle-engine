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
pub const UploadedResource = loader_mod.UploadedResource;
pub const Texture = loader_mod.Texture;
pub const AssetLoaderVTable = loader_mod.AssetLoaderVTable;

pub const WorkRequest = worker_mod.WorkRequest;
pub const WorkResult = worker_mod.WorkResult;

/// Re-exported so games (via the assembler-generated `main.zig`) can
/// call `setBackend` with adapters that forward to `labelle-gfx`'s
/// `decodeImage` / `uploadTexture` / `unloadTexture`. Also exposed so
/// integration tests in `test/asset_catalog_test.zig` can inject a
/// mock backend via `engine.ImageLoader.setBackend`.
pub const image_loader = @import("loaders/image.zig");

test {
    // Pull every file in the module tree into the test binary. The
    // `zig build test` step rooted at this file (see `build.zig`'s
    // `assets_tests` entry) is what actually runs these — a separate
    // module root is needed because Zig only discovers in-source
    // `test` blocks in files that belong to the same module as the
    // test binary's root, and all of `test/*.zig` live in a module
    // that only sees `engine` through a cross-module import.
    _ = catalog_mod;
    _ = loader_mod;
    _ = worker_mod;
    _ = image_loader;
    _ = @import("loaders/audio.zig");
    _ = @import("loaders/font.zig");
}
