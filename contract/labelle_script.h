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
 *     NULL only together with a 0 capacity — the NULL/cap-0 call is
 *     each out-writing function's documented sizing probe (see the
 *     sizing convention below and the per-function comments).
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
 *     is a boolean 1/0 — and labelle_component_batch_set (v1.3), which
 *     adds -2 = int-typed-field refusal on top of the 0/-1 pair.
 *     labelle_plugin_call carries the same rc in a size_t: 0 =
 *     dispatched, LABELLE_PLUGIN_CALL_UNROUTABLE ((size_t)-1) =
 *     failure — see its section. labelle_component_batch_get (v1.3)
 *     likewise carries its int-field refusal as
 *     LABELLE_BATCH_INT_REFUSED ((size_t)-2) in its size_t return —
 *     check it BEFORE treating the return as a required size.
 *   - Out-parameter sizing: labelle_component_get and labelle_query
 *     return the bytes the COMPLETE result REQUIRES (snprintf-style;
 *     required > out_cap is the truncation signal — retry right-sized;
 *     NULL/cap-0 out is a legal pure sizing probe; 0 keeps its
 *     sentinel meaning: absent / unknown / dead / malformed). They
 *     differ in what an under-sized cap writes: the query fills a
 *     truncated-at-the-last-whole-id prefix that is still valid JSON,
 *     while component_get writes ALL-OR-NOTHING (a truncated JSON
 *     object prefix is useless — on overflow the buffer is untouched).
 *     labelle_event_poll alone returns bytes WRITTEN, because a real
 *     poll consumes its entry, truncation included; its sizing story
 *     is the paired NULL/cap-0 probe, which returns the NEXT entry's
 *     size without consuming — probe, grow, then poll.
 *     labelle_plugin_call (v1.2) is required-size / all-or-nothing
 *     like the get, but do not probe or cap-retry IT — a call executes
 *     the plugin's handler again; its probe/retry legs live on the
 *     paired, side-effect-free labelle_plugin_response_fetch (see the
 *     plugin-commands section).
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
 * labelle_contract_version() at plugin startup and refuse a mismatch.
 *
 * The version bumps on BREAKING changes only — the check is an
 * exact-match refusal, so a bump on additions would strand every
 * still-compatible consumer. ADDITIVE growth (new exports) is a MINOR
 * revision instead: the export is marked "since v1.x" and its presence
 * is probed per-symbol (embedded VMs bind against the running host,
 * which either exports it or doesn't; native plugins find out at link
 * time) — the editor-bridge contract's exact convention (its v1.1–v1.7
 * were all additive). This header describes contract v1.3:
 *   v1.1 = v1 + labelle_plugin_call (labelle-engine#744);
 *   v1.2 = v1.1 + plugin-call responses — out/out_cap activated per
 *          their reserved semantics + labelle_plugin_response_fetch
 *          (labelle-engine#758; probe for the fetch symbol);
 *   v1.3 = v1.2 + bulk component access — the packed component codec
 *          (labelle_component_get_packed / _set_packed) and the
 *          batched query (labelle_component_batch_get / _batch_set)
 *          (labelle-scripting#41; probe for the symbols — an older
 *          host simply doesn't export them and the binding keeps the
 *          JSON / per-entity paths). */
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

/* Find an entity by name, via a registered `Name` (or `Tag`) component
 * carrying a string field (name/value/tag). Returns the first live
 * match's id, or 0 = no match / empty name / the game registers no such
 * component (the lookup is compiled out for those — a zero-cost always-0)
 * / not bound. Names are not required unique; the first the view yields
 * wins. First-match snapshot over the ECS view at call time. */
uint64_t labelle_entity_find(const char *name, size_t name_len);

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
 * (all defaults). The payload must be a single JSON document: trailing
 * bytes after it (beyond whitespace — plus comments for the built-ins,
 * which parse as JSONC) are a parse error. 0 = ok; -1 = unknown
 * component / unknown-or-dead entity / parse error. On -1 the entity
 * is untouched. */
int32_t labelle_component_set(uint64_t id,
                              const char *name, size_t name_len,
                              const char *json, size_t json_len);

/* Serialize component `name` of entity `id` to JSON into `out`
 * (capacity `out_cap`). Returns the bytes the COMPLETE JSON requires
 * (snprintf-style, like labelle_query); 0 = absent / unknown name /
 * dead entity. The write is ALL-OR-NOTHING: `out` is filled only when
 * the whole JSON fits (required <= out_cap) — a truncated JSON object
 * prefix is useless, so on overflow nothing is written; retry with a
 * buffer of the returned size. NULL/cap-0 `out` is a legal pure
 * sizing probe. Scene built-ins serialize as a scene could have
 * authored them — see the support table above. */
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
 * COMPLETE result requires, snprintf-style (the shared sizing
 * convention — see the conventions block above). 0 = malformed input /
 * not bound. Unknown names yield the valid empty result "[]"
 * (required size 2).
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
 * present in the JSON). VOID-payload events (the union tag declares no
 * payload struct) accept exactly: empty (NULL/len 0), the exact bytes
 * "{}", or the exact bytes "null" — anything else, malformed JSON
 * included, is a parse failure. 0 = ok; -1 = unknown event name /
 * parse failure / the game declares no events. */
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
 * (FIFO, emission order) into `out` and returns bytes WRITTEN; 0 =
 * inbox empty. A real read consumes the entry even when `out_cap`
 * truncates it — but no caller needs to eat a truncation: a NULL or
 * zero-capacity `out` is the paired no-consume SIZING PROBE, returning
 * the NEXT entry's full size (0 = inbox empty) while reading and
 * consuming nothing — probe, grow the buffer, then poll. An entry is
 * never empty, so a probe's non-zero return cannot be confused with
 * inbox-empty. Drain in a while (poll() > 0) loop once per tick.
 * Beyond an internal cap of pending events, further events are
 * dropped newest-first until the script polls. */
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

/* ── Input ────────────────────────────────────────────────────────────
 *
 * Read-only polling over the host's unified input, valid during the
 * plugin's tick (main thread). `key` is the backend-agnostic KeyboardKey
 * code (the engine enum's integer value) — an unknown code simply reads
 * as not-down. Safe no-ops before the host binds (keys not-down, mouse at
 * the origin). */

/* 1 while `key` is held down this frame; 0 otherwise. */
int32_t labelle_input_key_down(uint32_t key);

/* 1 on the frame `key` transitions up→down (the press edge); 0
 * otherwise. */
int32_t labelle_input_key_pressed(uint32_t key);

/* Write the current mouse position into *x_out / *y_out; either pointer
 * may be NULL to skip that axis. 0 on backends with no mouse. */
void labelle_input_mouse(float *x_out, float *y_out);

/* ── Plugin commands (since v1.1 #744; responses since v1.2 #758) ─────
 *
 * Call a named command on a Zig engine PLUGIN (e.g. pathfinder
 * "navigate") — the script-side entry to the same handler channel
 * labelle-studio's plugin panels use (the editor-bridge v1.7/v1.8
 * editor_plugin_command exports): a plugin registers ONE handler by
 * subscribing to the `engine__editor_plugin_command` engine event, and
 * that single registration is reachable from studio panels AND every
 * scripting language alike.
 *
 * Since v1.2 a handler may RESPOND (engine.plugin_command.respond,
 * called inside the synchronous dispatch; one response per command,
 * first-writer-wins) and the caller receives it — either directly in
 * the call's `out` buffer, or afterwards through the side-effect-free
 * labelle_plugin_response_fetch. Responses are host-capped (currently
 * 4096 bytes); the fetch probe returns exact per-response sizes, so no
 * caller needs to hard-code the cap. */

/* labelle_plugin_call's failure sentinel: the rc convention's -1
 * carried in its size_t return. Distinct from 0 = dispatched — and
 * from any response-size return, which could never require the whole
 * address space. */
#define LABELLE_PLUGIN_CALL_UNROUTABLE ((size_t)-1)

/* Dispatch command `command` of plugin `plugin` with `params_json` as
 * the arguments object — NULL/len 0 means "{}" (no arguments). The
 * dispatch is SYNCHRONOUS: the plugin's handler has run by the time
 * this returns, and all three strings are borrowed for the call only
 * (stack/reused buffers are fine).
 *
 * Return (size_t):
 *   0                               dispatched into the handler
 *                                   channel; no handler responded (the
 *                                   v1.1 fire-and-forward outcome).
 *                                   Also the outcome for an EMPTY
 *                                   response (handlers that want a
 *                                   bare ack respond "{}"), and for
 *                                   ANY dispatched call made in the
 *                                   v1.1 NULL/0 shape — the compat
 *                                   rule below. Results can still
 *                                   arrive as game events
 *                                   (labelle_event_subscribe/poll).
 *   N                               a handler responded (since v1.2);
 *                                   the response requires N bytes and
 *                                   was written into `out` only when
 *                                   N <= out_cap (ALL-OR-NOTHING, like
 *                                   labelle_component_get — otherwise
 *                                   `out` is untouched).
 *   LABELLE_PLUGIN_CALL_UNROUTABLE  not routable: empty plugin/command
 *                                   name, no plugin registered a
 *                                   handler in this build, or the host
 *                                   is not bound.
 *
 * V1.1-COMPAT RULE: a call with out == NULL and out_cap == 0 — the ONE
 * shape the v1.1 header sanctioned ("v1.1 never writes to `out`; pass
 * NULL/0") — keeps the exact v1.1 rc contract: it returns 0 for every
 * dispatched call, EVEN when a handler responded, so a binding built
 * against v1.1 that checks rc == 0 never misreads a successful
 * responding dispatch as failure. The response is still stored: a
 * caller without a buffer sizes/reads it via
 * labelle_plugin_response_fetch (probe with NULL/0 THERE — never by
 * re-calling here). The fold is exactly that shape and no wider:
 * out != NULL with out_cap == 0 is the v1.2 sizing leg (N returned,
 * nothing written), and NULL out with a nonzero cap — illegal per the
 * conventions block (NULL only together with cap 0) — is tolerated as
 * sizing too, matching labelle_component_get's NULL tolerance.
 *
 * DOUBLE-EXECUTION WARNING: unlike component_get, do not "retry
 * right-sized" (or NULL/cap-0 probe) by calling AGAIN — every call
 * executes the handler again. On N > out_cap, read the stored response
 * via labelle_plugin_response_fetch instead; it never re-executes.
 *
 * Calls may NEST: a handler may itself issue a labelle_plugin_call
 * mid-dispatch (bounded only by the game's own recursion depth). Each
 * call's response travels in per-call host storage — an inner call
 * never corrupts the enclosing call's response — and each call
 * publishes the fetch store as it COMPLETES, inner first, outer last,
 * so a fetch made after the whole stack unwinds reads the OUTERMOST
 * call's outcome. A handler that wants the inner response reads it
 * from its own call's `out`, not from a later fetch.
 *
 * The channel is a broadcast the handlers name-filter THEMSELVES, so
 * the host cannot tell an unknown plugin/command from a
 * delivered-and-ignored one: both return 0 wherever a handler exists.
 * A caller that needs an acknowledgment asks the plugin to respond (or
 * listens for its response event). */
size_t labelle_plugin_call(const char *plugin, size_t plugin_len,
                           const char *command, size_t command_len,
                           const char *params_json, size_t params_len,
                           char *out, size_t out_cap);

/* Read the response of the most recently COMPLETED labelle_plugin_call
 * — the side-effect-free half of the response channel (since v1.2):
 * the handler is NEVER re-executed, so the shared sizing convention's
 * probe/retry legs live here. NULL/cap-0 `out` is the pure sizing
 * probe; otherwise the write is ALL-OR-NOTHING and the return is the
 * bytes the complete response requires. 0 = nothing stored (no call
 * yet, or the last completed call was unroutable / produced no
 * response). A stored response is never empty, so a non-zero return
 * cannot be confused with nothing-stored. NON-consuming — fetch
 * repeatedly; the store is replaced (or cleared) as each
 * labelle_plugin_call COMPLETES, whatever that call's outcome —
 * "completed" being the nesting rule above: after nested calls unwind,
 * the store holds the OUTERMOST call's outcome. */
size_t labelle_plugin_response_fetch(char *out, size_t out_cap);

/* ── Bulk component access (since v1.3, labelle-scripting#41) ─────────
 *
 * Two additive fast paths over the per-entity JSON component ops.
 * Both are probed BY SYMBOL (this contract's additive convention): an
 * older host doesn't export them, and the binding keeps the JSON /
 * per-entity paths as its degrade route.
 *
 * 1. PACKED CODEC — a binary twin of labelle_component_get/set for
 *    scalar-only components, killing the JSON text round-trip. Wire
 *    format (little-endian, self-describing):
 *
 *      [u8 field_count]                 ; 0xFF = "not packable"
 *      repeat field_count times:
 *        [u8 name_len][name bytes][u8 tag][value bytes]
 *      tag: 0=f32(4B)  1=i64(8B)  2=bool(1B)  3=u64(8B)
 *           4=f64(8B, SET-side only — since v1.3)
 *
 *    GET emits only tags 0..3. The binding may SET tag 4 for a float
 *    that would lose precision through f32's 24-bit mantissa (a Float
 *    destined for an int field past 2^24) — the host coerces it at
 *    full f64 precision (float->int exact, under the same range
 *    refusal). A pre-tag-4 host reads tag 4 as an unknown tag and
 *    refuses (-1); the binding then falls back to labelle_component_set
 *    (JSON), which carries the f64 faithfully. Additive, no version
 *    bump.
 *
 *    GET writes the single sentinel byte 0xFF (return 1) for any
 *    component the codec can't carry (non-scalar fields, f64 fields —
 *    the wire only has an f32 tag, and silent precision loss is not
 *    acceptable — built-ins with handles/strings, >=255 fields, a
 *    >255-byte field name) — the caller falls back to
 *    labelle_component_get, which carries all of those faithfully.
 *    SET refuses with -1 (fall back to labelle_component_set); a
 *    record with bytes past its declared fields is malformed (-1).
 *    Lossless for i64/u64 (unlike the batch stream below), including
 *    the 64-BIT BITCAST PAIR: a 64-bit int field accepts the OTHER
 *    64-bit tag via two's-complement bitcast (i64 tag -> u64 field and
 *    u64 tag -> i64 field), so a binding whose only integer type is
 *    signed 64-bit (mruby) round-trips u64 values bit-exactly — GET
 *    emits tag 3, the binding bitcasts to its signed integer, SET
 *    re-emits tag 1, the host bitcasts back. Narrower int fields keep
 *    the range-checked refusal (-1 on overflow — never clamped).
 *    A BOOL field accepts ONLY the bool tag (2): every numeric tag
 *    (0/1/3/4) targeting a bool field is type confusion and refuses
 *    (-1 -> JSON fallback), so a number mis-addressing a bool field
 *    surfaces rather than silently collapsing to true/false. The
 *    reverse — a bool tag widening into a number field (true/false ->
 *    1/0) — is allowed (total, lossless, unambiguous).
 *
 * 2. BATCHED QUERY — one call moves ALL matching entities' scalar
 *    component data as a flat f32 stream, collapsing the 4-per-entity
 *    FFI crossings of a hot loop into 2 per tick. The entity set is
 *    the labelle_query set (all entities carrying every named
 *    component), walked in query order; per entity, each named
 *    component's scalar fields in given-name order then
 *    struct-declaration field order, one little-endian f32 per field
 *    (f64 narrows, bool is 0/1; non-scalar fields are skipped
 *    identically in both directions).
 *
 *    INT-FIELD REFUSAL: a named component with ANY int-typed field is
 *    refused outright (LABELLE_BATCH_INT_REFUSED from _batch_get, -2
 *    from _batch_set) — i64/u64 would silently corrupt through f32's
 *    24-bit mantissa. Keep int-carrying components on the per-entity
 *    paths (the packed codec carries ints losslessly).
 *
 *    GET/SET SYMMETRY (read-modify-write): everything _batch_get emits
 *    is writable. _batch_set fetches each queried component, overwrites
 *    ONLY the scalar fields the stream carries (the exact mirror of the
 *    get walk), preserves non-scalar fields, and applies through the
 *    same channels as the per-entity set (built-ins included — a
 *    batched Camera zoom write routes through the scene apply
 *    machinery). No default-constructibility is required.
 *
 *    POSITIONAL COUPLING: the stream carries no entity ids; _batch_set
 *    re-resolves the query and applies the floats positionally. Do NOT
 *    spawn or destroy entities between a paired _batch_get and
 *    _batch_set. As a cheap guard, _batch_set PREFLIGHTS: it sizes the
 *    re-queried set FIRST and refuses -1 with NO writes unless buf_len
 *    matches exactly (a count change since the get; a same-count
 *    membership or order change is undetectable — hence the rule
 *    above). On -1 nothing was applied: re-get and recompute. */

/* labelle_component_batch_get's int-field refusal sentinel: the rc
 * convention's -2 carried in its size_t return. Distinct from 0 =
 * malformed/not-bound and from any required-size return. */
#define LABELLE_BATCH_INT_REFUSED ((size_t)-2)

/* Packed GET: serialize component `name` of entity `id` into `out` as
 * the packed record above. Sizing/return conventions are EXACTLY
 * labelle_component_get's: returns the bytes the complete record
 * requires, all-or-nothing write, NULL/cap-0 sizing probe, 0 = absent
 * / unknown name / dead entity / not bound. A non-packable component
 * writes the 0xFF sentinel and returns 1. */
size_t labelle_component_get_packed(uint64_t id,
                                    const char *name, size_t name_len,
                                    char *out, size_t out_cap);

/* Packed SET: apply a packed record to component `name` of entity
 * `id`, coercing each named field into the field's actual scalar type.
 * REPLACE semantics like labelle_component_set (absent fields take the
 * struct defaults). 0 = ok; -1 = refuse (unknown component / dead
 * entity / non-scalar or non-default-constructible target / malformed
 * record / not bound) — fall back to labelle_component_set. */
int32_t labelle_component_set_packed(uint64_t id,
                                     const char *name, size_t name_len,
                                     const char *buf, size_t buf_len);

/* Batched GET: `names_json` is the labelle_query names array (e.g.
 * ["Position","Velocity"]). Writes [u32 entity_count][f32 stream] into
 * `out`. Returns the bytes the COMPLETE buffer requires
 * (snprintf-style — retry right-sized), LABELLE_BATCH_INT_REFUSED on
 * an int-carrying named component, 0 = malformed names / not bound.
 * Zero matching entities return the 4-byte count-0 header (distinct
 * from the 0 sentinel). NULL/cap-0 `out` is a pure sizing probe. */
size_t labelle_component_batch_get(const char *names_json,
                                   size_t names_json_len,
                                   char *out, size_t out_cap);

/* Batched SET: `buf` is the pure f32 stream (NO count header) laid out
 * exactly as _batch_get returned it. Re-resolves the query and applies
 * positionally, routed through the same apply path as the per-entity
 * set so hooks and dirty-tracking fire. 0 = ok; -1 = malformed names /
 * entity-count mismatch (see the coupling guard above) / not bound;
 * -2 = int-carrying named component. */
int32_t labelle_component_batch_set(const char *names_json,
                                    size_t names_json_len,
                                    const char *buf, size_t buf_len);

#ifdef __cplusplus
}
#endif
