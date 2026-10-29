# Persistent settings

`engine.settings.Settings(T, Codec, max_bytes)` is a typed preference lifecycle over `engine.storage.Store`. Use a settings-specific directory/namespace to keep preferences outside the save-slot list. Storage selection remains with the caller and works with immediate or asynchronous providers.

`T` must own its values: use scalars, fixed arrays, and value structs, not borrowed slices or allocated pointers. `Codec.decode(bytes) T` validates the schema, copies values and chooses malformed-data defaults; `Codec.encode(value, buffer) ![]const u8` serializes into the supplied bounded buffer. This lets existing games preserve their JSON formats and migrations.

Create an instance with `init(allocator, "sound.json", defaults)` and call `pump(store)` on the game thread each frame, including while paused. Never spin waiting for a browser operation. `ready()` becomes true when the initial read finishes or falls back; use it to hold localized startup UI until preferences are available. An absent file keeps defaults. Other read errors are returned once, leave defaults usable, and allow a subsequent save. Unavailable providers or a caller-defined startup deadline can call `disable()` to continue in memory.

`set(value)` updates live preferences. `save()` queues a snapshot; `saveIfChanged()` commits only when a setter ran. Writes wait for the initial read, are serialized, and coalesce queued saves. Uncommitted edits made after save are not written accidentally. A user edit made before an async read completes wins over the older stored value. Write failures return an error and disable persistence for that instance, preserving live values. Show/log the error rather than reporting a successful save.

Keep the store and name alive while in use. Call `deinit()` on shutdown before destroying the store. Dropping an operation releases its observer, but does not undo a write already submitted. Flush via normal frame pumping after user changes; do not rely on shutdown to persist browser preferences. The layer does not itself choose a startup timeout, locale policy, or cloud synchronization.
