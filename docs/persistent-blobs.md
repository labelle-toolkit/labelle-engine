# Persistent blobs — engine #893

`engine.storage` separates persistence from engine JSON and game save slots.
The engine supplies the contract, native file implementation, asynchronous web
adapter, target default selection, and engine byte serialization. Browser
bindings are owned by labelle-web and exposed by the selected backend.

## API and ownership

`Store.begin(allocator, Request)` returns an owned `Operation`. Requests are
`read { name, max_bytes }`, `write { name, bytes }`, `list`, and `delete name`.
Inputs need only live until `begin` returns. Poll on the game thread:

- `null`: still pending; retain the operation and return to the frame loop.
- `Result`: completed; ownership transfers to the caller exactly once.
- A typed error: failed; do not report a successful save.

Always call `Operation.deinit`; call `Result.deinit(allocator)` for returned
read bytes or listing entries. Dropping a pending observer does not cancel
an already submitted write. Do not copy live operations by value. File calls
complete in `begin`; browser calls return pending and never block on IndexedDB.

Errors include `NotFound`, `TooLarge`, `QuotaExceeded`, `Unavailable`,
`AccessDenied`, `ReadOnly`, `IoFailure`, `OutOfMemory`, `InvalidName`, and
`InvalidOperation`. Errors can arise in either `begin` or `poll`.

Keys are portable UTF-8 basenames, at most 128 bytes. Absolute/relative paths,
separators, traversal, Windows device names, control characters, and alternate
data streams are rejected. `.meta` has no special status: `colony.json` and
`colony.meta` are independent blobs. List returns owned names, byte sizes and
modification timestamps in nanoseconds; order is unspecified. Delete is
idempotent. Reads enforce an inclusive size cap, including zero-byte blobs.

`storage.Default(Backend).init(allocator, options)` selects native files or
`Backend.PersistentStorage` on emscripten. `options.app_id` is a stable namespace;
`options.native_directory` preserves an existing game save location. Relative
legacy paths resolve once at initialization. An explicitly injected
`options.store` takes precedence and does not consult native paths. Keep the
selected instance at a stable address after obtaining its Store, and deinit it
after all operations. The caller supplies exactly one Store. The engine has
no mutable global provider registry, no last-wins behavior, and no implicit
file fallback for failed web storage. Rejecting two package claims at resolve
time belongs to the runtime-service resolver and remains unwired here.

## Engine JSON

`game.serializeGameState()` returns JSON owned by `game.allocator`.
`game.deserializeGameState(bytes)` performs the existing version/shape checks
and ECS reconstruction. Save format and entity remapping remain engine-owned.
The existing explicit file methods use those same byte functions.

A slots controller should serialize, begin a write, free its serialized
buffer, and poll over subsequent frames. Only after `.written` may it submit
the ordinary metadata blob and report the appropriate save outcome. Metadata
failure must not claim the world write failed or atomically roll it back:
these are separate transactions. Load reads bytes and hands them to the engine.
On replacement, invalidate old metadata before writing a new world, aborting
if invalidation fails. Otherwise a failed metadata write could associate the
new world with old metadata. Losing optional metadata is preferable to that
stale association. UI and slot sequencing belong to FP #949 / #950.

## Files and stable roots

`Files.init(io, absolute_directory)` borrows the directory string. Normally
use `<resolved root>/saves`. A missing namespace lists empty; only writing
creates it. Writes use a temporary file under `.pending`, flush file data,
then atomically replace the destination. A failed flush preserves the old
blob. Listings exclude temporary files and directories. There is no guarantee
against sudden power loss of the directory rename: the directory itself is
not fsynced. File operations currently run synchronously.

`storage.dataRoot.resolve(allocator, Inputs)` is a pure, owned-string resolver:

1. Absolute `LABELLE_DATA_DIR` override, when supplied.
2. Android: supplied app-private internal data directory, or `Unavailable`.
3. Windows: `LOCALAPPDATA/<app_id>`.
4. macOS: `HOME/Library/Application Support/<app_id>`.
5. Linux: `XDG_DATA_HOME/<app_id>` or `HOME/.local/share/<app_id>`.

An invalid configured path is an error, never a fallback to cwd. Windows paths
rooted on an unspecified current drive are rejected. `Default` reads environment values and the Android native activity
internal data path; the caller supplies its stable application ID. No
service/target files are modified, and existing FP directories are not moved.

## Web binding contract

`storage.Web(Bindings){ .namespace = app_id }` supplies a Store. Bindings expose:

```zig
begin(namespace: []const u8, kind: u32, name: []const u8,
      bytes: []const u8, max_bytes: usize) u32
status(id: u32) i32
length(id: u32) usize // a u32 return also works on wasm
copy(id: u32, destination: []u8) bool
release(id: u32) void
```

Kinds: read=0, write=1, list=2, delete=3. Begin returns a nonzero handle, zero
means unavailable. Status: pending=0, committed=1, not found=-1, quota=-2,
unavailable=-3, access denied=-4, oversized=-5, other I/O failure=-6.
Read payloads are raw bytes. List payloads are UTF-8 JSON arrays of
`{ "name": string, "size": unsigned integer, "modified_ms": signed integer }`.
The adapter converts milliseconds to nanoseconds. Payloads are copied before
release. All operation results/errors are terminal and consumed once.

The paired independent bgfx files `src/web_storage.c` and
`src/web_storage.zig` implement this contract. The C bridge stores Blob records
in IndexedDB database `labelle.blobs.<namespace>`, object store `blobs`, schema
version 1. Write success is set only on transaction completion, not request
success. Strict transaction durability is requested. Listing reads Blob size
metadata without transferring all world payloads into wasm.

## Validation and integration limits

On Windows with Zig 0.16.0: `zig build test-save-storage -j2 --summary all`
passes 50 tests, including the existing save/load policy and two-phase tests.
Coverage includes reopen, multi-save, overwrite, metadata independence,
idempotent delete, size errors, a failed flush preserving old content,
temporary-file isolation, stable roots, async completion, malformed results,
and allocation-failure cleanup.

Compile the actual cross-repo bindings (object-only; no emcc link):

```powershell
zig build-obj -target wasm32-emscripten -lc --dep storage --dep storage-bindings `
  '-Mroot=test/storage_web_compile.zig' '-Mstorage=src/storage.zig' `
  '-Mstorage-bindings=C:/prj/save-chain-20260926-web/src/web_storage.zig' `
  '-femit-bin=.zig-cache/storage-web-abi.o'
```

The fixture uses the generated wasm root's non-I/O panic policy to avoid Zig
0.16's known default-panic/Threaded emscripten compilation failure.

The labelle-web Node tests exercise the actual EM_JS factory with fake-indexeddb,
including a fresh runtime over the same database, recovery after abnormal
connection closure, and a synthetic 16 MiB blob. They are not real-browser
reload tests. Full FP integration evidence belongs to the dependent FP PR.

The selected backend provides only bindings; persistence policy and engine
serialization remain independent of graphics. Exactly-one-package-claim
validation remains a runtime-service resolver gate, outside this change.
Explicit Store injection works today; this does not claim that the future
provider-resolution architecture is complete. Android default path selection
is implemented but an emulator/device persistence run has not been performed.
