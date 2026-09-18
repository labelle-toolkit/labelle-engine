# Shader migration: engine validation evidence

Environment: Windows, Zig 0.16.0. Commands: `zig build test -j4 --summary all`, plus direct `zig test` invocations for the baseline preview binaries.

Baseline snapshots: engine `6b5a448` and core `b734e0c`, extracted without edits. The current engine uses the completed generic-shader core. Both broad comparison runs were stopped after collecting the relevant failure evidence; they are **not completed suite runs**.

The earlier completed current full run reported 237/258 build steps succeeded, 1246/1293 tests passed, 47 runtime failures, and 12 failed steps. Its raw log was removed during cleanup. The retained partial rerun and baseline logs below provide narrower, explicit evidence; no claim is made that every broad-suite issue has been baseline-reproduced.

Passing targeted evidence: engine `test-shader-regressions` 78/78 (including 13 shader tests); gfx `test` 181/181. Independent integration validation passes 20 example tests, 16 shader compilations, and 16 runtime scenarios, including the subsequently added game-owned mist effect.

## Runtime failures: baseline reproduced

All 47 preview-family runtime failures have now been reproduced on the original baseline. Each fails during loopback harness initialization with `GetSockNameFailed`, before the behavior under test. Baseline preview-mode: 10 pass / 29 fail; frame-stream: 0 pass / 10 fail; handshake: 0 pass / 7 fail; flows API: 6 pass / 1 fail. The direct baseline commands for the last three groups completed before the broader comparison was stopped.

### test/preview_mode_test.zig (29 failures)

- Preview: hello round-trip over loopback TCP — `GetSockNameFailed`.
- Preview: heartbeats arrive at the listener in order — `GetSockNameFailed`.
- Preview: tickHeartbeat respects the rate limit — `GetSockNameFailed`.
- Preview: full lifecycle — hello, heartbeats, bye, EOF — `GetSockNameFailed`.
- emitEntityCreated: writes magic+kind+length+payload with optional prefab name — `GetSockNameFailed`.
- emitEntityDestroyed: writes magic+kind+length+entity_id — `GetSockNameFailed`.
- emitComponentChanged: only emits when component is subscribed — `GetSockNameFailed`.
- pollSubscription: decodes subscribe and unsubscribe from editor — `GetSockNameFailed`.
- Preview: JSON heartbeats and binary frames multiplex on one socket — `GetSockNameFailed`.
- pollSubscription: malformed JSON surfaces MalformedSubscription — `GetSockNameFailed`.
- Game lifecycle: createEntity + addComponent emit telemetry; destroy + filter respected (#520) — `GetSockNameFailed`.
- emitNodeEntered: emits one binary frame when flow is subscribed — `GetSockNameFailed`.
- emitNodeEntered: no-op when flow is not subscribed — `GetSockNameFailed`.
- emitNodeEntered: stops firing after unsubscribe_flow — `GetSockNameFailed`.
- emitNodeEntered: exact wire-format guard against drift — `GetSockNameFailed`.
- pollSubscription: subscribe_flow / unsubscribe_flow update subscribed_flows — `GetSockNameFailed`.
- emitPinValue: no-op when flow is not pin-subscribed — `GetSockNameFailed`.
- emitPinValue: subscribed flow emits a frame with the expected layout — `GetSockNameFailed`.
- emitPinValue: unsubscribe_pin_values stops emission — `GetSockNameFailed`.
- emitPinValue: subscribing to flow A doesn't enable emission for flow B — `GetSockNameFailed`.
- emitPinValue: pin_name with non-ASCII and quotes round-trips through the wire — `GetSockNameFailed`.
- emitPinValue: f64 value preserves precision through encode/decode — `GetSockNameFailed`.
- emitPinValue: exact wire-format guard against drift — `GetSockNameFailed`.
- pollSubscription: subscribe_pin_values / unsubscribe_pin_values update subscribed_pin_flows — `GetSockNameFailed`.
- watch_entity: adds id to watched_entities and filters subsequent emits — `GetSockNameFailed`.
- unwatch_entity: empty set restores Phase 2 'watch everything' behaviour — `GetSockNameFailed`.
- emitEntitySnapshot: writes one component_changed frame per (entity, component) — `GetSockNameFailed`.
- emitEntitySnapshot: skips components the editor did not subscribe to — `GetSockNameFailed`.
- emitEntitySnapshot: bypasses watched_entities filter for unwatched ids — `GetSockNameFailed`.

### test/preview_frame_stream_test.zig (10 failures)

- beginFrameStream emits frame_offer + leaves producer in .offered — `GetSockNameFailed`.
- publishFrame writes pixels into the SHM ring; consumer reads them back — `GetSockNameFailed`.
- publishFrame returns StreamNotActive when state is .offered (editor hasn't accepted) — `GetSockNameFailed`.
- publishFrame returns StreamNotActive when called without beginFrameStream — `GetSockNameFailed`.
- beginFrameStream resets frame_state even when re-offer is in progress — `GetSockNameFailed`.
- publishFrame returns InvalidFrameSize when buffer size mismatches dims — `GetSockNameFailed`.
- publishFrame increments frame_idx monotonically across multiple publishes — `GetSockNameFailed`.
- beginFrameStream after frame_resize re-offers at new dims, old ring is torn down — `GetSockNameFailed`.
- endFrameStream tears down ring, subsequent publishFrame is StreamNotActive — `GetSockNameFailed`.
- endFrameStreamIOSurface is a no-op when SHM mode is active — `GetSockNameFailed`.

### test/preview_handshake_test.zig (7 failures)

- sendFrameOffer serializes expected JSON and flips state to offered — `GetSockNameFailed`.
- sendFramePublished carries frame_idx and produce_ns — `GetSockNameFailed`.
- frame_accept transitions offered → accepted; isFrameAccepted reports it — `GetSockNameFailed`.
- frame_accept from not_offered is ignored (no spurious transition) — `GetSockNameFailed`.
- frame_resize sets pending_resize, takeResize pops it once and resets state — `GetSockNameFailed`.
- frame_resize with missing dim fields surfaces MalformedSubscription — `GetSockNameFailed`.
- unknown control frame is still rejected (regression guard) — `GetSockNameFailed`.

### test/flows_game_api_test.zig (1 failures)

- preview: codegen pattern `if (game.preview) |*_p| _p.emitNodeEntered(...)` resolves — `GetSockNameFailed`.

## Compilation failures

| Location | Error | Baseline evidence |
|---|---|---|
| `test/font_loader_test.zig:143:57` | `expected type 'void', found 'u64'` | Reproduced in baseline broad run; also observed in current rerun. |
| `test/asset_catalog_test.zig:128:57 and :186:57` | `expected type 'void', found 'u64'` | Reproduced in baseline broad run; also reported by the earlier current full run. |
| `test/atlas_surface_crosswire_test.zig:239:41` | `expected integer or vector, found 'void'` | Reproduced in baseline broad run. Current comparison did not reach this binary before interruption. |
| `test/preview_capture_test.zig → std/Io/Writer.zig:1803:5` | `invalid format string 'd' for type '*anyopaque'` | Reproduced in baseline broad run; also reported by the earlier current full run. |
| `test/jsonc/image_component_test.zig:183:58` | `expected type 'void', found 'u64'` | Observed in current rerun; baseline execution not established. |
| `test/root_test.zig:589:57` | `expected type 'void', found 'u64'` | Observed in current rerun; baseline execution not established. |
| `test/load_deadline.zig:81:20` | `expected integer or vector, found 'void'` | Observed twice in current rerun; baseline execution not established. |

The `timespec` errors arise in POSIX sleep helpers whose time fields resolve to `void` on this Windows target. For the three current-only locations, the test source is byte-identical to engine `6b5a448`; that is source evidence, **not proof from a baseline execution**. They are therefore classified as existing-source/platform failures with baseline runtime verification incomplete, not demonstrated shader regressions.

### Current-only compile roots involving load_deadline

- `test/asset_streaming_shim_test.zig`
- `test/image_load_shim_test.zig`

## Transient compiler failure

The current broad rerun once failed loading Zig's `std/crypto/codecs/asn1/der.zig` with `Unexpected`, while compiling `test/set_sprite_flip_test.zig`. A direct rerun of that current binary passed all 4 tests. This error did not reproduce; it is not classified as an introduced source failure.

## Limits and process cleanup

No introduced failure was established by the evidence gathered. The broad suite is not certified green. All current/baseline suite process trees were stopped; a process inventory found no `zig.exe`, `build.exe`, or `test.exe` remaining. Demo PID 32672 was preserved. Raw logs were moved outside the repository into the local temporary evidence directory; no scratch scripts or logs are included in the commit.
