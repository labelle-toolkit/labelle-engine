/* labelle_script.h — Script Runtime Contract v1 (labelle-engine#737,
 * RFC-LANGUAGE-PLUGINS).
 *
 * The one versioned C-ABI surface every scripting language binds. The
 * host game (assembler-generated, engine `src/script_contract.zig`)
 * exports these flat symbols; language plugins consume them:
 *
 *   - embedded-VM languages (Lua, mruby, QuickJS, CoreCLR) call them
 *     from binding closures;
 *   - native-compiled languages (Rust, Crystal, Go) declare them
 *     `extern "C"` — this header IS the binding — and link against the
 *     host binary.
 *
 * Conventions
 *   - Strings are (pointer, length) pairs — NOT NUL-terminated.
 *   - Nullability: required string parameters (component/event/scene/
 *     prefab names, log messages, the query's names_json) must be
 *     non-NULL even when their length is 0. Only JSON payloads
 *     documented "NULL/len 0" may be NULL, and `out` buffers may be
 *     NULL only together with a 0 capacity (treated as capacity 0:
 *     nothing written; 0 returned — except labelle_query, whose
 *     NULL/cap-0 call is a legal sizing probe returning the required
 *     size).
 *   - Structured payloads are UTF-8 JSON (encoding v1).
 *   - Components are addressed BY NAME over the game's own component
 *     registry plus the engine built-ins JSONC scenes author: "Position"
 *     ({"x":…,"y":…}) and the five scene built-ins "Sprite", "Shape",
 *     "Tilemap", "Camera", "Image" — routed through the scene loader's
 *     own apply machinery (see the support table before
 *     labelle_component_set).
 *   - Events are addressed by the game's `GameEvents` union tag name
 *     (e.g. "turret__fired", "engine__tick"); payloads are the variant
 *     struct as JSON.
 *   - Entity ids are u64; 0 is never a valid id and doubles as the
 *     failure sentinel.
 *   - rc convention: functions returning int32_t yield 0 = ok and
 *     -1 = failure (unknown name / unknown-or-dead entity / parse
 *     error / host not bound), except `labelle_component_has`, which
 *     is a boolean 1/0.
 *   - Out-parameter functions return bytes written; 0 = absent /
 *     unknown / empty / doesn't fit. Two-call sizing is deliberately
 *     not offered — script payloads are small, size buffers generously.
 *     The ONE deliberate exception is labelle_query, the contract's
 *     only unbounded-cardinality op: it returns the bytes the complete
 *     result REQUIRES (snprintf-style) while writing at most `out_cap`,
 *     so callers can detect truncation and retry right-sized.
 *   - Main-thread only; calls are valid during the plugin's tick.
 *   - Before the host binds its game (once, at startup, before plugin
 *     setup), every call is a safe no-op following the same
 *     conventions (0 / -1 / no bytes).
 */
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The contract version this header describes. Compare against
 * labelle_contract_version() at plugin startup and refuse a mismatch. */
#define LABELLE_CONTRACT_VERSION 1u

/* Contract version the host binary was built with. Pure — callable
 * before anything else. */
uint32_t labelle_contract_version(void);

/* ── Entities ─────────────────────────────────────────────────────── */

/* Create an empty entity. Returns its id, or 0 when the host is not
 * bound. */
uint64_t labelle_entity_create(void);

/* Destroy an entity (children cascade, same as the engine's
 * destroyEntity). Unknown / already-dead ids are ignored. */
void labelle_entity_destroy(uint64_t id);

/* Spawn a named prefab (requires a JSONC scene to have been loaded —
 * the standard assembled-game boot). `params_json` is optional: pass
 * NULL/len 0 to spawn at the origin, or a {"x":…,"y":…} object for the
 * spawn position (unknown keys ignored). Returns the root entity id,
 * or 0 on failure (unknown prefab, malformed params, not bound). */
uint64_t labelle_prefab_spawn(const char *name, size_t name_len,
                              const char *params_json, size_t params_len);

/* ── Components (by name, JSON payloads) ──────────────────────────── */

/* Built-in component support (write-parity with JSONC scenes — `set`
 * dispatches through the very apply branches the scene loader uses,
 * with its precedence: a project-registered component named Tilemap /
 * Camera / Image WINS and routes through the registry instead; Sprite /
 * Shape are always the built-ins, in scenes too). All five also
 * resolve in labelle_query.
 *
 *   name      set  get  has  remove   notes
 *   Position  yes  yes  yes  yes      set routes through setPosition so
 *                                     render dirty-tracking fires
 *   Sprite    yes  yes* yes  yes      set/remove register/untrack the
 *                                     renderer (addSprite/removeSprite)
 *   Shape     yes  yes* yes  yes      same channel as Sprite
 *                                     (addShape/removeShape)
 *   Tilemap   yes  yes  yes  yes      set decodes the referenced .tmx
 *                                     (where the renderer has the seam);
 *                                     remove frees the decoded runtime
 *                                     (removeTilemap)
 *   Camera    yes  yes  yes  yes      `tag` is carried as a JSON string
 *                                     both ways; remove drops the
 *                                     authored seed (the live camera
 *                                     keeps its last seeded state)
 *   Image     yes  yes  yes  yes      plain data component
 *
 * yes* — get omits fields that are renderer HANDLES rather than
 * authored data (e.g. gfx Sprite's `texture`); they re-derive from the
 * authored fields (`sprite_name`) on the next set, so get→set is still
 * lossless. Camera's get emits {"zoom":…,"viewport":…|null,"tag":"…"}.
 *
 * Built-in sets follow the scene loader's LENIENT field semantics: a
 * wrong-typed field with a declared default falls back to that default;
 * malformed JSON and non-object payloads are refused with -1 (entity
 * untouched). */

/* Set component `name` on entity `id` from a JSON object. REPLACE
 * semantics: the JSON is parsed as the whole component struct — absent
 * fields take the component's declared defaults, unknown fields are
 * ignored; there is no merge/patch. Empty json (NULL/len 0) means "{}"
 * (all defaults). 0 = ok; -1 = unknown component / unknown-or-dead
 * entity / parse error. On -1 the entity is untouched. */
int32_t labelle_component_set(uint64_t id,
                              const char *name, size_t name_len,
                              const char *json, size_t json_len);

/* Serialize component `name` of entity `id` to JSON into `out`
 * (capacity `out_cap`). Returns bytes written; 0 = absent / unknown
 * name / dead entity / doesn't fit. Scene built-ins serialize as a
 * scene could have authored them — see the support table above. */
size_t labelle_component_get(uint64_t id,
                             const char *name, size_t name_len,
                             char *out, size_t out_cap);

/* 1 when the entity carries the component, else 0 (absent, unknown
 * name, dead entity). */
int32_t labelle_component_has(uint64_t id, const char *name, size_t name_len);

/* Remove component `name` from entity `id`. Idempotent on the
 * component (absent-but-known removes return 0). 0 = ok; -1 = unknown
 * component name / unknown-or-dead entity. */
int32_t labelle_component_remove(uint64_t id, const char *name, size_t name_len);

/* ── Queries ──────────────────────────────────────────────────────── */

/* Query entity ids by component names. `names_json` is a JSON array of
 * component names (["CloudDrift","Position"]); the host iterates a
 * view on the FIRST name and filters on the rest, writing the matching
 * ids as a JSON array ([3,7,12]) into `out`. Returns the size the
 * COMPLETE result requires, snprintf-style — the one written-bytes
 * exception in the contract, because a query's cardinality (every
 * matching entity) is the one thing a caller cannot bound up front.
 * 0 = malformed input / not bound. Unknown names yield the valid empty
 * result "[]" (required size 2).
 *
 * Writing fills `out` up to `out_cap`, truncated at the last whole id,
 * so the written prefix is always valid JSON. A return larger than
 * `out_cap` means the result was truncated — retry with a buffer of
 * the returned size to get the full set. NULL/cap-0 `out` is a legal
 * pure sizing probe: nothing written, required size returned.
 *
 * Snapshot semantics: the id list is captured at query time — spawning
 * or destroying entities while walking it is safe (component_get on a
 * since-destroyed id returns 0). */
size_t labelle_query(const char *names_json, size_t names_json_len,
                     char *out, size_t out_cap);

/* ── Events (emit + subscribe/poll drain) ─────────────────────────── */

/* Emit a game event by union-tag name into the engine's buffered event
 * path — flows (OnEvent), Zig hooks, and other subscribed scripts all
 * see it at this frame's dispatch. Empty json (NULL/len 0) means "{}"
 * (all-default payload; payload fields without defaults must be
 * present in the JSON). 0 = ok; -1 = unknown event name / parse
 * failure / the game declares no events. */
int32_t labelle_event_emit(const char *name, size_t name_len,
                           const char *json, size_t json_len);

/* Declare interest in an event name. A subscription takes effect for
 * events emitted AFTER the current tick's drain: events already
 * buffered this tick (e.g. the engine's own emits, which precede
 * script execution) — or emitted later within this same tick — are
 * never delivered to it, so subscribing mid-tick cannot replay a past
 * the script never subscribed to. Delivery starts with the next tick's
 * events. Duplicates are deduped. Subscribing before the host binds is
 * a no-op (plugin setup always runs after bind in the generated
 * main). */
void labelle_event_subscribe(const char *name, size_t name_len);

/* Drain one pending event: copies the next "<name> <json>" entry
 * (FIFO, emission order) into `out` and returns bytes written; 0 =
 * inbox empty. The entry is consumed even when `out_cap` truncates it
 * — size `out` generously. A NULL or zero-capacity `out` is the one
 * exception: it reads (and consumes) nothing and returns 0. Drain in a
 * while (poll() > 0) loop once per tick. Beyond an internal cap of
 * pending events, further events are dropped newest-first until the
 * script polls. */
size_t labelle_event_poll(char *out, size_t out_cap);

/* ── Scene / log / time ───────────────────────────────────────────── */

/* Switch to a registered scene by name. 0 = ok (including a swap
 * deferred on asset streaming — the engine retries it); -1 = unknown
 * scene (the running scene is untouched) / not bound. */
int32_t labelle_scene_change(const char *name, size_t name_len);

/* Log through the game's log sink at info level, "[script]"-prefixed. */
void labelle_log(const char *msg, size_t len);

/* The last tick's GAMEPLAY delta-time in seconds — the same scaled dt
 * Zig scripts receive: the value stamped for this tick via
 * labelle_time_dt_stamp when the language plugin stamps, else the
 * host's own record of the last tick (real frame time × time_scale,
 * 0 while paused and before the first tick). */
float labelle_time_dt(void);

/* Stamp the tick's gameplay delta-time. Called once per tick by the
 * scripting LANGUAGE PLUGIN, with the scaled dt the host handed it,
 * before it runs the frame's scripts — game scripts must not call it.
 * Once a session has stamped, labelle_time_dt returns the stamped
 * value exactly, so every script observes the very dt Zig scripts
 * received this tick even when a script changes the time scale
 * mid-tick. Ignored before the host binds. */
void labelle_time_dt_stamp(float dt);

#ifdef __cplusplus
}
#endif
