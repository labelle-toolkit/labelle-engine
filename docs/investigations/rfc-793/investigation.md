# Engine PR #793: implementation-readiness investigation

Investigated 2026-09-09 UTC. **Verdict: sound objective, useful existing foundation, but the full RFC needs design closure before implementation.** The frame shorthand can be a small first implementation after validation and lifetime rules are specified. Triggers, marker delivery, and pause migration are not adequately specified yet.

This record describes the investigation of RFC head `997a3a8`, before the readiness revision in PR #793. It is not a feature implementation or a PR approval. Thread statuses below are the pre-revision snapshot; the revised RFC and current PR threads describe subsequent changes.

## Scope and source baselines

- [PR #793](https://github.com/labelle-toolkit/labelle-engine/pull/793): open, documentation only; two commits; current head `997a3a89d448f7c52f3527c1533823df391a7082` (July 20). Read the complete 305-line RFC, all 17 inline threads, all four review submissions, and the one top-level discussion comment. Thread pagination is complete. At the investigation snapshot, sixteen threads were unresolved; one was resolved. All submitted reviews are `COMMENTED`, not approvals.
- [RFC at the reviewed head](https://github.com/labelle-toolkit/labelle-engine/blob/997a3a89d448f7c52f3527c1533823df391a7082/RFC-EVENT-DRIVEN-ANIMATION.md).
- Engine `main`: `46677c9ac2b45eaedbbdab13903a037d64c0fc84` (v2.18.0).
- Assembler `main`: `cabe3711d5d3da2c3d1bff9f9c5bbe51343920e3`.
- Core `main`: `5425b7c4d04920da4da25af221c139e928a1b918`.
- Flying Platform `main`: `38fd2c3b10e9383588343d874665099a34fb2813`. Confirmed the moca-tecnologia fork and the local checkout's Flying-Platform origin report the same SHA.
- Also traced the generated bgfx desktop loop used by the WFC acceptance build. This checks the concrete consumer ordering, rather than trusting an engine comment about where generated code drains events.

At the investigation snapshot, the PR description and issue [#794](https://github.com/labelle-toolkit/labelle-engine/issues/794) listed four pieces while the RFC added a fifth, pause unification. The readiness revision aligns the PR description; the tracker must include this fifth workstream before implementation begins.

## Disposition of every inline review thread

The classification below is independent of GitHub's resolved flag. A comment can be historically correct on the old PR branch and no longer describe current main.

| Review thread | Assessment against current code and RFC | Required disposition |
| --- | --- | --- |
| [Dispatch, target matching and repeated triggers](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617053166) | Still valid. Vocabulary validation, match order, ancestor rules and repeated-play behavior remain open. | Specify the contract and executable examples. |
| [Large-dt marker crossing](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617053170) | Still valid. Wraps, repeated crossings, once-clamp, ping-pong endpoints and ordering remain unspecified. | Add traversal examples and an overflow policy. |
| [Diagram fence language](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617053173) | Valid minor formatting issue; the fence is still untyped. | Add `text`; not an implementation blocker. |
| [Legacy `event_frames` alias](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617053176) | Marked resolved, but wording remains ambiguous. Section 4 preserves landed-on behavior; lines 273–274 still call it an alias of the crossing path. | Say explicitly that timing remains separate, or make an explicit behavioral change. Do not infer semantic equivalence from “alias.” |
| [Autodrive infrastructure absent](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063845) | Correct on the old PR source tree, stale against current main: the mixin and opt-in driver now exist. | Rebase/update baseline; do not implement a second driver. |
| [Existing frame-event infrastructure absent](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063850) | Likewise stale against main: `event_frames`, event payloads and forwarding exist. | Update baseline and preserve the real existing behavior deliberately. |
| [AnimationDef transitions absent](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063855) | Likewise stale against main: `TransitionRule` and transition tables exist. | Reuse them; still define the trigger-to-clip binding. |
| [Runtime names versus typed GameEvents](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063862) | Still a fundamental design gap. Runtime JSON strings cannot directly construct arbitrary typed union payloads. | Choose a typed mapping or a generic marker channel. |
| [Events with no target](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063867) | Still valid. Engine and custom event payloads do not share one target schema. | Define target extraction, validation, and broadcast behavior. |
| [Playback state for actions](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063872) | Still valid. No per-instance playing/paused/stopped state or action table exists. | Define state, timer/frame effects, and repeated requests. |
| [Dormant catch-up after loading](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617063876) | Still valid. SpriteAnimation is transient; edge events alone cannot reconstruct a previously true condition. | Specify reconciliation or a post-load state synchronization step. |
| [Unscaled updates during pause — CodeRabbit](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617248127) | Requirement valid; placement premise needs updating. Current animation advancement is already before the pause return, but its zero-scaled-dt/subsystem gates would still exclude unscaled clips. | Specify clock selection and the gates precisely. |
| [Unscaled updates versus pause return — Codex](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617271661) | Partly stale for the same reason. Unscaled support remains missing, but moving the existing driver before the pause return is not new work. | Consolidate with the preceding thread after correcting the baseline. |
| [Trigger pass before event drain](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617271669) | Core concern valid. Its quoted ordering is not the current bgfx generated order: root/plugin ticks and dispatch occur before `g.tick`, including engine animation advancement. | Define the dispatch integration across generated loops; a normal animation-buffer scan is insufficient. |
| [Pause notifications](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617271672) | Still valid. `setTimeScale` does not emit `pause_changed`; `setPaused` does. | Specify notification behavior for explicit pause versus zero scale. |
| [Restore pre-pause scale](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617271676) | Still valid and reproduced. Existing resume resets scale to 1.0. | Keep a separate pause multiplier or preserve the prior scale. |
| [Normalize authored event names](https://github.com/labelle-toolkit/labelle-engine/pull/793#discussion_r3617271681) | Contract gap valid; blanket rejection of `__` spelling would be overstated. Current assembler retention accepts both dotted and qualified names in JSONC. | Specify canonical author spelling, namespace resolution and accepted aliases; retain a single mapping. |

None of the review summaries or green documentation checks constitutes implementation acceptance.

## Findings that determine readiness

### 1. Define the event bridge before implementing markers or triggers

`emit(event: GameEvents)` accepts a concrete union value. `emitEngineEvent` requires a comptime tag and checks required fields. A marker carrying just an entity cannot construct, for example, an existing event whose payload requires both an entity and an amount. Unknown or elided event names must not quietly become no-ops. [Event implementation](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/game/events_mixin.zig#L31)

Recommended starting point: one typed marker notification containing entity, marker name, frame and repetition. This resembles the named marker information already produced by AnimationDef. If the product requirement is specifically to emit existing custom event variants, use a generated, validated mapping with an explicit supported payload shape or an authored payload adapter. Those are different contracts; pick one in the RFC. A generic marker notification is not an implementation of arbitrary named GameEvents.

For incoming triggers, define target extraction explicitly. Do not assume every event's field is called `entity`, or that a field naming a source/actor is the animation target. Untargeted events can require explicit broadcast scope. Define what happens after an entity is destroyed, a world resets, or ancestry changes between enqueue and delivery. A generation/world identity or a validated lifetime policy is needed to prevent stale IDs targeting new entities.

Core also supports consumable events: an animation listener needs a stated position and behavior relative to consumers that can stop delivery. A separate buffer tap would observe events regardless of later consumption; a normal listener might not. Neither behavior follows automatically from the JSON shape. [Dispatcher contract](https://github.com/labelle-toolkit/labelle-core/blob/5425b7c4d04920da4da25af221c139e928a1b918/src/dispatcher.zig#L121)

### 2. Integrate triggers with actual dispatch, not a guessed “frame buffer”

The traced bgfx desktop sequence is root/plugin updates, optional scripting event tap, buffered dispatch, engine `g.tick` (including SpriteAnimation), then rendering. Engine-tick events can therefore reach the next drain, while root-script events have already been removed when engine animation runs. Reading the buffer only in the existing animation pass misses an important producer path. `emitSync` bypasses the buffer altogether. [Assembler sequence](https://github.com/labelle-toolkit/labelle-assembler/blob/cabe3711d5d3da2c3d1bff9f9c5bbe51343920e3/src/codegen/lifecycle/render.zig#L233), [engine drain](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/game/events_mixin.zig#L185)

Prefer a defined dispatch listener that queues animation commands, followed by a defined application boundary. Document whether a dispatched play request displays frame zero immediately or on the next animation update. Do not mutate or destroy ECS components from marker callbacks while an animation view/pointer is live. Handler-emitted events currently wait for the next buffered drain; preserve that boundary unless a separate change is intended. Marker → trigger → marker cycles must not turn into an unbounded same-dispatch loop.

The hooks delivery-contract work in [#857](https://github.com/labelle-toolkit/labelle-engine/issues/857) and ordering work in [assembler #723](https://github.com/labelle-toolkit/labelle-assembler/issues/723) should share these decisions. Completing every hooks enhancement is not a prerequisite to frame shorthand.

### 3. Crossing accuracy is not a guarantee of unlimited delivery

The current scratch event buffer has 32 entries; overflow returns false and existing callers commonly discard that result. The reference AnimationDef traversal also stops after 512 crossed beats. Reusing it cannot substantiate the RFC's absolute “never dropped” promise. `game.emit` can additionally fail allocation and only log it. [Buffer](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/animation_events.zig#L72), [reference traversal](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/animation_def.zig#L653)

Specify chronological order, frame-zero entry, repeated hits across loops, endpoint behavior, marker/completion ties, repeated marker entries, and once-completion exactly once. Choose either bounded exact delivery with explicit overflow reporting, or another bounded representation such as aggregated counts for appropriate cue types. Do not introduce an unbounded per-frame catch-up loop for large dt. Cosmetic sound cues and authoritative damage events may need different overload policies. The fallible enqueue contract in [#856](https://github.com/labelle-toolkit/labelle-engine/issues/856) is relevant to the transport part.

### 4. Playback actions and recovery need a state machine

Specify at least playing, paused, stopped/dormant and completed, and each action's effects on frame, residual timer, direction, repetition, pending markers and visible sprite. Current consumers sometimes remove SpriteAnimation and explicitly restore an idle image. Thus “stop” cannot safely mean “freeze wherever it is” without an intentional migration decision.

Define loop retrigger versus once retrigger; both `play` and `action` in one entry; multiple matching entries/events; mode changes mid-clip; speed zero; start/restart at frame zero; and whether the initial marker fires without positive dt. An action such as `restart` must refresh the visible sprite even when the subsequent tick does not cross a frame boundary.

On load, transient playback state is rebuilt. A dormant clip waiting for an edge cannot discover that its associated machine was already active before the save. Choose an initial-state reconciliation/binding step or a domain-emitted synchronization event after state restoration. Incremental entity-ready callbacks should not be treated as whole-scene completion.

### 5. Pause migration must include the generated loop and the consumer

The engine currently computes `scaled_dt = dt * time_scale` before checking its explicit pause flag. The animation driver is in the always-run section. A probe confirms `setPaused(true)` freezes `elapsedSeconds()` but still advances SpriteAnimation when scale remains 1. The clock and animation already disagree for that pause path. [Engine ordering](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/game/loop_mixin.zig#L49)

Recommended model: retain configured time scale, derive effective scaled dt from an explicit pause state, and pass real dt separately to systems opted into unscaled updates. Define animation-only suppression independently of global pause. The RFC currently says it removes subsystem pause state but also preserves a shim that pauses only that subsystem: explain the retained underlying behavior.

Do not migrate Flying Platform by just setting scale to zero. Its Escape-to-resume handler lives in a normal script `tick`, and the generated root/plugin tick block is gated by positive scaled dt. That migration would stop the Escape handler. Move pause/menu input to an always-running path as part of the consumer change. This is a source-derived failure scenario, not a newly executed game UI test. [Consumer handler](https://github.com/moca-tecnologia/flying-platform-labelle/blob/38fd2c3b10e9383588343d874665099a34fb2813/scripts/playing/97_pause_menu.zig#L232)

Tests must cover explicit pause, zero scale, slow motion → pause → resume, pause notifications, unscaled clips, subsystem suppression, and keyboard/menu unpause.

### 6. Frame shorthand needs a loader contract

This is feasible, but “zero risk” is not supported. The generic component deserializer only walks actual struct fields; it does not expand aliases. It requires `frames`, and unknown optional JSON fields can be ignored. A dedicated normalization/validation seam is needed before component construction. [Deserializer](https://github.com/labelle-toolkit/labelle-engine/blob/46677c9ac2b45eaedbbdab13903a037d64c0fc84/src/jsonc/deserializer.zig#L215)

Define inclusive range bounds, supported placeholder grammar, padding width, reversed/empty ranges, integer overflow and allocation limits. Current SpriteAnimation permits at most 255 frames. Specify the behavior when both explicit frames and a pattern are authored. Missing atlas frames may need staged validation because assets can load asynchronously; distinguish bad syntax from a not-yet-ready atlas.

Do not unconditionally append `.png` to every generated sprite key: the toolkit also supports extensionless grid-frame keys. Treat formatting as producing atlas keys, with extension behavior explicit. Store the resulting slice in the per-world arena and intern strings through the existing mechanism, rather than borrowing temporary parsed JSON or retaining a new permanent slice per spawn.

### 7. Current consumer evidence does not support the estimated script deletion yet

The one-line autodrive setup is real and can disappear under an explicit new default. But several advertised candidates currently reconcile model state each frame, rather than merely receiving existing edges:

- Kitchen gates match working kitchens to overlays by grid cell; hierarchy is deliberately not the mapping.
- Condenser gates derive active workstation IDs from WorkProgress and assignment queries, and restore an idle frame when work stops.
- Disabled-room decoration suppression uses spatial bounds, skips worker-owned sprites, and changes animation speed's sign.
- WC slot entities are not necessarily parented to the room; current lookup can use Room storage relationships.
- The RFC's `sewer__machine_on`, `sewer__machine_off`, and `sewer__pulse` example names were not found in the inspected current events/scripts/hooks/packs.

This does not invalidate declarative animation. It means the RFC needs one real pilot with domain event producers, target binding and load reconciliation. Do not promise removal of roughly half the scripts until that pilot works. Keep continuously derived character animation and domain ownership outside the generic animation engine.

### 8. Event retention mostly has the needed foundation already

The assembler consumption filter already scans `.json` and `.jsonc` for both dotted and qualified plugin event names. Explicit prefab references in those supported spellings should already preserve variants. There is no evidence that a new blanket scanner is required. [Consumption scan](https://github.com/labelle-toolkit/labelle-assembler/blob/cabe3711d5d3da2c3d1bff9f9c5bbe51343920e3/src/codegen/scan/event_consumption.zig#L12)

Nevertheless test root and staged-pack prefabs, namespace rewriting, local shorthand if introduced, runtime-loaded authored data, and unknown/elided events. A generic marker event needs its engine channel retained even if authored JSON contains only a marker label. Use the existing force-consumption mechanism where appropriate. Name validation and retention must use consistent metadata.

## Executed checks

Zig 0.16.0, native macOS, isolated snapshots of the exact engine/core revisions above. A small local build harness selected four existing test files plus six audit probes; production source was unchanged. **36/36 passed.** The six probes deliberately assert observed baseline limitations; they are investigation fixtures, not desired-behavior regression tests for the future implementation. These passes verify the current behavior described below, including its limitations. They do not mean the proposed RFC features were tested or implemented.

| New probe | Observed result |
| --- | --- |
| Explicit `setPaused(true)` with scale 1 | Clock freezes; animated sprite advances one frame. |
| `setTimeScale(0)` | Sprite frame remains unchanged. |
| Scale 0.5 → `pause()` → `resume_()` | Scale becomes 1.0. |
| Legacy marker at frame 1, tick lands on frame 2 | No marker event. |
| Sprite animation advances through 40 loops | Repetition reaches 40; only 32 events retained. |
| AnimationDef advances through 50 loops with an entry marker | Repetition reaches 50; buffer has 32 entries and cannot contain all 51 marker occurrences. |

The existing suites contributed 30 passing tests: engine-driven sprite animation (4), AnimationDef/sprite event behavior (13), sprite event forwarding (5), and engine event delivery (8).

Evidence: [probe source](probes.zig), [build/run log](probes.log), and [reproduction instructions](README.md). The observations test the exact source versions above; do not wire these baseline-asserting probes into production CI as permanent requirements. All 17 original review threads are linked individually above.

Static inspection additionally covers loader lifetime, current generated bgfx ordering, typed event construction, event retention, consumer mapping and Escape-to-resume. No full Flying Platform build, visual migration, cross-platform loop run, or proposed-feature benchmark was performed for this investigation.

## Decisions and acceptance gates before implementation

| Work unit | Decision to close | Minimum acceptance |
| --- | --- | --- |
| Frame shorthand | Grammar, frame-key/extension policy, bounds, ownership, diagnostics | Equivalent explicit/pattern frames; first/last/255-frame boundaries; malformed/overflow/reversed ranges; extensionless keys; repeated spawn/reset lifetime. |
| Named markers | Generic notification vs arbitrary typed event mapping; traversal and delivery limits | Entry/wrap/once/ping-pong order; repeated crossings; bounded huge dt; observable overflow; malformed payload/name rejection; no unbounded cycles. |
| Triggers | Component/state layout; dispatch phase; targets; consumption; action table | Real generated root/pack events; sync and buffered modes; two machines isolated; broadcast; conflicting/repeated requests; deleted targets; restart visual; scene reload of an active machine. |
| Pause | Effective clocks, notifications, suppression, always-run input | Both pause APIs; unscaled progression; slow-motion restoration; independently paused animations; Escape/menu resume; generated native and callback loops. |
| Default driving | Explicit default/migration policy and single owner of advancement | Exactly one advancement with migrated consumers; documented manual-driver opt-out; no dependency on guessed script filenames; no-animation project. |

Recommended sequence: first rebase and update the RFC and tracker; land shorthand; then one marker contract with bounded delivery; then triggers with one real consumer pilot; finally pause/default migration as a separate cross-repository change. Choose a SpriteAnimation-only first trigger scope unless a concrete AnimationDef binding is included and tested. This removes open design choices from implementation PRs without requiring the entire hooks roadmap first.
