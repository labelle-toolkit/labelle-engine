/* Script Runtime Contract — v0 POC surface (RFC-LANGUAGE-PLUGINS).
 *
 * The one shared piece every language plugin binds: a flat C-ABI symbol
 * namespace the host game exports. Components are addressed BY NAME with
 * JSON payloads (encoding v1) — the same serde-reflection dispatch the
 * engine's `editor_set_component` bridge already proves at runtime.
 *
 * Embedded-VM languages (Lua, mruby, CoreCLR) call these from binding
 * closures; native-compiled languages (Rust, Crystal) declare them
 * `extern "C"` and link against the host. Both families consume the
 * IDENTICAL surface — that equivalence is what this spike demonstrates.
 *
 * v0 scope: entities, components, events, time, log. The full v1 adds
 * queries, input, prefab spawn, scene change (see the RFC).
 */
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t labelle_entity_create(void);
void     labelle_entity_destroy(uint64_t id);

/* JSON in; the host validates + stores (real engine: serde dispatch). */
void labelle_component_set(uint64_t id,
                           const char *name, size_t name_len,
                           const char *json, size_t json_len);

/* Copies the component JSON into `out` (cap `out_cap`); returns bytes
 * written, 0 when absent. Two-call sizing is deliberately avoided in v0
 * — script payloads are small. */
size_t labelle_component_get(uint64_t id,
                             const char *name, size_t name_len,
                             char *out, size_t out_cap);

int  labelle_component_has(uint64_t id, const char *name, size_t name_len);

void labelle_event_emit(const char *name, size_t name_len,
                        const char *json, size_t json_len);

/* Receive side (the RFC's subscribe/poll model): a script declares
 * interest, then DRAINS its inbox once per tick. Each poll copies the
 * next pending event as "<name> <json>" into `out` and returns bytes
 * written; 0 = inbox empty. Dispatch-to-handlers is language-plugin
 * sugar over this drain loop (Lua callbacks, Rust match, C# events). */
void   labelle_event_subscribe(const char *name, size_t name_len);
size_t labelle_event_poll(char *out, size_t out_cap);

float labelle_time_dt(void);
void  labelle_log(const char *msg, size_t len);

#ifdef __cplusplus
}
#endif
