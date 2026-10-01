# RFC: Declarative, event-driven sprite animation

## Status and scope

**Agreed behavioral design; implementation and acceptance remain outstanding.**
The September 9 investigation checked current engine, assembler, core and
Flying Platform code, all 17 PR review threads, and 36 focused tests. See the
[investigation and review dispositions](docs/investigations/rfc-793/investigation.md)
and [reproducible probes](docs/investigations/rfc-793/README.md).

Five workstreams make animation authoring simpler:

1. Drive SpriteAnimation by default, with one owner of advancement.
2. Expand frame ranges from authored patterns.
3. Start, stop and control playback from scoped events.
4. Emit named, crossing-accurate frame cues with an explicit delivery policy.
5. Define scaled/unscaled animation clocks and migrate pause behavior.

The September 10 design discussion agreed the package boundary, JSONC authoring,
targeting, dispatch, retriggering, marker crossings and pending delivery,
save/load continuity, clocks and default-driving migration recorded below.
Concrete API/schema layouts, numerical limits and backend integration still need
implementation specifications and validation. Publishing this RFC does
not close [#794](https://github.com/labelle-toolkit/labelle-engine/issues/794).

## Motivation and current baseline

Simple animated props should be authorable as prefab data. Continuous character
state, room ownership and gameplay decisions remain the game's responsibility.
The target is less repeated playback code, not a second game state machine.

Baseline: engine `46677c9` (v2.18.0), assembler `cabe371`, core `5425b7c`;
full revisions and source links are in the investigation. The original RFC
branch predates this foundation; it has now been brought up to current main.

- `SpriteAnimation` already has frames, fps, boundary mode, per-clip speed and
  numeric `event_frames`. The component is transient; prefab loading recreates
  it and resets playback state. The current frame-count limit is 255.
- The engine's `game/loop_mixin.zig` already advances it when
  `drive_sprite_animations` is enabled. The flag still defaults to false.
- The driver already emits buffered frame, completion and loop events. Legacy
  frame cues fire when a tick lands on a marked frame; they can miss crossings.
- `AnimationDef` already has named marker metadata, crossing traversal and
  `TransitionRule` tables. Those facilities are reusable, but their output is
  not a generic runtime-string-to-GameEvents emitter.
- `game.emit` accepts a typed union value. `emitEngineEvent` requires a
  comptime tag and a compatible payload. `emitSync` bypasses the buffer.
- Animation scratch buffers retain at most 32 events. AnimationDef traversal
  is also bounded to 512 crossed beats. Existing overflow can be discarded;
  copying that code does not guarantee every cue is delivered.
- Explicit pause and zero time scale are currently different paths. Animation
  runs before the engine's pause return, gated by subsystem pause and nonzero
  scaled dt. `setPaused(true)` can freeze the clock while sprites still advance.

The three old review comments claiming the driver, frame events and transition
tables do not exist describe the old branch, not this baseline. The remaining
design concerns must not be dismissed on that basis.

## 1. Default animation driving

The proposed default is engine-owned advancement. Keep an explicit opt-out for
games that intentionally drive animation themselves. Do not add a second tick
or infer the owner solely from a guessed legacy script filename.

Agreed rollout: introduce compatibility diagnostics for existing manual drivers,
then change the engine default in a major release with consumer migration.
Advance each automatically driven instance exactly once per update; explicit
manual ownership excludes it from automatic advancement. The assembler,
generated loops and engine configuration must agree. The no-animation path
should remain inexpensive; this RFC makes no unmeasured zero-cost claim.

Acceptance: exactly one advance per frame, manual-driver opt-out, the migrated
Flying Platform setup, and a project without SpriteAnimation. Default-on is a
separate rollout gate from frame-pattern support.

## 2. Frame-range shorthand

### Package and authored-definition boundary

Animation is a top-level package **inside the labelle-engine repository**,
alongside the existing `scene/` and `jsonc/` packages, not merely a
`src/animation/` directory:

```text
labelle-engine/
  animation/
    build.zig
    build.zig.zon
    src/
    test/
  scene/
  jsonc/
  src/                  # engine integration
```

The package owns definitions, JSONC parsing/validation, playback, trigger and
marker mechanics, and definition reload/reconciliation mechanics. Engine-specific
ECS, event-dispatch, persistence and game-loop adapters stay in engine `src/`.
The package must not import the engine that imports it: use explicit interfaces
for entity validation, event delivery and resource resolution. Depend on the
existing JSONC package where appropriate. Consolidate the existing AnimationDef
foundation rather than create a competing animation system; preserve public
engine exports during migration. Its own build/tests must run independently.

Games author shared definitions in `animations/*.jsonc`. Definitions contain
clips, frame ranges, markers, default speed and clip transitions. Prefabs refer
to a definition, choose initial playback settings, and declare event/target
bindings where those depend on the prefab. Each entity owns separate playback
state. For example (illustrative schema, not a shipped API):

```jsonc
"SpriteAnimation": {
  "definition": "animations/wc_door.jsonc",
  "clip": "closed"
}
```

The assembler discovers/packages these assets and validates typed event
bindings; the engine loads and validates definitions at runtime. Shared
definition lifetimes must cover playback and pending marker references across
hot reload. Specify migration from existing definitions and inline authoring;
do not silently change existing file interpretation.

### Expansion contract

Illustrative authoring syntax, subject to the validation contract below:

```jsonc
"SpriteAnimation": {
  "frames_pattern": "sewer/sewer_machine/sewer_machine_{frame:04}.png",
  "from": 1, "to": 10,
  "fps": 8, "mode": "loop"
}
```

Normalize the pattern into the same frame-key slice used by explicit `frames`
before constructing the component. The generic deserializer currently walks
real struct fields and requires `frames`; optional unknown fields can be
ignored. Merely adding JSON keys does not implement this feature.

Frame keys are exact atlas identifiers. No implicit `.png` suffix: extensionless
grid keys such as `tiles/0` are also valid. Authors include any desired extension
in the pattern. Preserve explicit `frames` support.

Agreed expansion behavior and remaining implementation limits:

- Expand at definition load. `from`/`to` are inclusive; `{frame:04}` denotes
  decimal frame numbering padded with zeroes to width four. Reject malformed
  patterns and reversed ranges; reverse playback uses direction, not reversed
  authoring bounds. Finalize the accepted placeholder/width limits explicitly.
- Checked arithmetic before allocating, and the current 255-frame ceiling.
- Explicit-list/pattern conflict handling. The old proposal silently preferred
  `frames`; the recommended rule is a diagnostic when both are authored.
- Syntax diagnostics versus resource readiness. Validate keys when the atlas
  becomes available; an asynchronously loading atlas is not a malformed key.
- Ownership: expanded slices belong to the shared definition's lifetime, with
  no borrows from temporary parsed JSON and no expansion allocation on every
  prefab respawn. Reuse existing interning with compatible resource lifetimes.

Acceptance: equivalence with an explicit list; first/last frames; range and
allocation boundaries; extensionless keys; missing-frame diagnostics; repeated
spawn/reset lifetime; representative root and pack prefabs.

## 3. Scoped event-triggered playback

The proposed surface remains declarative. These event names are illustrative
domain events, not existing Flying Platform events:

```jsonc
"SpriteAnimation": {
  "frames_pattern": "machine_{frame:04}.png", "from": 1, "to": 10,
  "fps": 8, "start": "dormant",
  "triggers": [
    { "on": "factory.machine_on", "play": "loop" },
    { "on": "factory.machine_off", "action": "stop" }
  ]
}
```

### Event identity and typed payloads

Validate `on` against discovered event metadata. Dotted provider/event names
are the recommended author spelling; current assembler retention also accepts
qualified `provider__event` spelling in JSONC. Specify alias and pack-namespace
resolution once and reuse it for validation, code generation and inspection.
Unknown names must produce actionable diagnostics.

The existing consumption filter scans JSON/JSONC for both spellings. Reuse it;
test events referenced only by root/pack prefabs, staged dependency prefabs,
and any runtime-loaded authoring path. A newly introduced generic marker
channel must be retained when only a marker label appears in authored data.

### Targeting and lifetime

**Agreed policy:** exact-entity targeting by default, explicit groups, and
opt-in broadcast. There is no implicit ancestor walk. These are semantic target
forms; concrete authored syntax remains to be chosen. Each trigger explicitly
maps its typed payload to the target, for example `worker_id`; the assembler
validates/generates that adapter. Never infer a target field or silently fall
back to broadcast. Validate lifetime at dispatch and again at application.

| Target | Recipients | Lookup strategy |
| --- | --- | --- |
| Entity (default) | One explicitly identified entity subscribed to the event | Direct entity lookup and binding match. |
| Group/owner | Matching subscribers in an explicitly owned group | A maintained membership list. |
| Broadcast (opt-in) | All subscribers matching the event and trigger filters | That event's subscriber list. |

The game owns group membership: rooms, machines and squads can define groups
without imposing an ECS parent hierarchy. Maintain membership on spawn, removal,
ownership changes and destruction. Reparenting changes a group only when the
game's ownership rule says it should. Kitchen overlays can use room-cell binding.

Resolve the recipient set once when the event is dispatched. Later group joins
do not receive the old event; leaving the group afterward does not retract a
command already addressed to a still-live entity. Use generation-checked group
and entity handles, including world identity/reset invalidation. Revalidate
entity handles at command application and skip destroyed recipients; a recycled
ID must never redirect a queued command. Group destruction retires membership
and its handle for future dispatch, without destroying members implicitly.

Define target extraction through typed metadata or a declared adapter; do not
guess from an arbitrary field named `entity`, which might identify an actor.
An event with no target needs explicit broadcast or an adapter. It must not
silently become broadcast under the default entity scope.

Animation advancement remains a separate ECS pass. Targeting must not scan all
animated entities for each individually targeted event. A broadcast to 500
recipients legitimately visits 500 recipients; 500 direct commands should not
require 500 full-world scans. Maintain subscriber indexes on binding lifecycle
changes, and benchmark targeting separately from ordinary frame advancement.

Choose the component boundary before implementation: fields on SpriteAnimation
or a sibling binding component. A first version restricted to SpriteAnimation
is recommended. AnimationDef reuse needs an explicit def/clip binding; existing
transition tables alone do not identify which game component to control.

### Playback state and repeated requests

Define playing, paused, stopped/dormant and completed states, with this action
table completed as part of the implementation specification:

| Request | Contract to specify |
| --- | --- |
| `play: once/loop/ping_pong` | Playing the same active clip with unchanged playback mode is a no-op, for every mode. Playing a different clip starts at frame zero with a new playback identity. Playing a completed/stopped clip starts it again with a new identity. Explicit mode changes and `play` on paused playback still require specification; `resume` is the continuation action. |
| `stop` | Agreed: reset playback to frame 0 and remain stopped. Reset the residual timer, direction, repetition and marker cursor; repeated stop is a no-op. An explicitly authored idle image may override the displayed image. Visibility is unchanged. |
| `pause` / `resume` | Agreed: pause preserves frame and residual timer; resume continues paused playback from that position. Repeated pause is a no-op. Define resume from stopped/completed and interaction with global/subsystem pause separately. |
| `restart` | Reset frame, timer, direction, repetition and marker cursor; create a new playback identity; update the visible sprite even without a later frame crossing. |
| `start: dormant` | Initial visible frame and behavior before the first request; reconciliation after loading. |

For example, a fan paused on frame 3 stays there and resumes from the same
position. Stopping resets it to frame 0 and leaves it stopped. A distinct
powered-off image is an explicit authored override, never inferred by the
engine; its configuration syntax remains to be specified. Stopping kitchen
smoke does not automatically hide its entity: visibility is separate state.
Resetting the displayed frame must work without a subsequent advancing tick.
Start/restart emits frame-zero markers once; resume/restore does not replay them.
Stop is a reset-to-stopped action, not a new playback start.

Reject conflicting `play` and `action` fields in one entry. Commands are applied
in dispatch order; matching entries within one event use authored trigger order.
Apply commands sequentially, so later commands determine the resulting state:
`play -> stop` ends stopped. Do not coalesce commands merely by keeping the last
one: `restart -> pause` must retain the reset before becoming paused.

Apply the complete boundary batch before advancing frames or emitting markers
caused by those commands. Intermediate commands must not emit transient cues
before a later conflicting command is applied. The final-state frame-zero cue
rule follows the crossing contract below. Address speed zero, mode changes
and completion explicitly.

Use explicit `restart` to synchronize recipients. Broadcast `play` alone does
not synchronize existing loops because the identical-loop request is a no-op.
A restart batch resets its recipients together at the animation boundary.

### Dispatch schedule and reentrancy

Do not have the normal animation tick merely scan “this frame's event buffer.”
The audited bgfx desktop order is:

```text
root/plugin updates -> scripting event tap -> buffered dispatch
    -> engine tick (SpriteAnimation and engine events) -> rendering
```

Root/plugin events are already drained when SpriteAnimation advances;
engine-tick events can reach the next drain. Synchronous events never enter
that buffer. Other generated loops need a checked, equivalent contract.

**Agreed policy:** dispatch resolves recipients and queues playback commands.
At one boundary per animation update, apply the queued batch in order, then
advance animations in one ECS pass and render. Freeze the batch at that boundary;
commands arriving after it wait for the next animation update. Buffered and
synchronous dispatch both enqueue commands rather than mutating live animation
components immediately. Exact generated-loop placement and first-frame display
timing must be specified consistently for native and callback backends.
Preserve once-per-drain delivery and the next-drain behavior of handler-emitted
events; command ordering is actual dispatch order, not enqueue timestamp order
across synchronous and buffered delivery.

**Consumption is respected:** events consumed by input/modal handlers must not
also enqueue animation reactions. Animation routing must run after the relevant
consumption decisions, and must not use an unconditional buffer tap that bypasses
them. The exact integration with native/flow handler ordering remains to be
specified. Prefer non-consumable domain notifications such as “machine activated”
after gameplay accepts an action; then every matching animation subscriber can
react without competing with input handling. Coordinate
with [delivery contracts #857](https://github.com/labelle-toolkit/labelle-engine/issues/857)
and [handler ordering](https://github.com/labelle-toolkit/labelle-assembler/issues/723).

Never execute arbitrary gameplay callbacks while an animation ECS view/pointer
is live. Marker-trigger cycles must not recursively drain or advance forever
in one frame. Bound pending commands and define visible overflow reporting.

### Load and state reconciliation

The current SpriteAnimation is transient; the agreed design adds persistence
where continuity matters. Save clip, playback position and residual time,
direction, repetition, paused/stopped/completed status, playback identity and
marker progress. Preserve pending crossed markers for saved entities and remap
their generation-checked entity references on restore. Do not re-emit markers
already delivered. Restore is not a new start or a replay of historical events.

Provide a post-restoration game hook to reconcile playback with authoritative
state (for example, cancel an attack that is no longer active). Restore references
and reconcile before pending cues can cause gameplay effects. Entity-ready
callbacks are not a whole-scene completion guarantee. Playback and pending
delivery state must be snapshotted consistently; specify the save boundary and
handoff to the normal event queue so a save cannot lose or duplicate a cue
between successful enqueue and hook delivery. This is not a promise of
transactional exactly-once external side effects. Version/reload identity and
the persisted representation remain implementation work.

Acceptance: two independently targeted props; group membership changes before
and after dispatch; group destruction and handle reuse; explicit broadcast;
missing/invalid targets; sync/buffered ordering; authored trigger order;
play/stop and restart/pause conflicts; consumed input versus domain notifications;
entity deletion and world reset; restart visibility and synchronized broadcasts;
an active prop restored without a new edge. Benchmark 1, 100 and 1,000 entities
with one broadcast, group dispatch, and many individually targeted events.
Report targeting cost separately from frame advancement, and verify unrelated
entities are not scanned by direct targeting.

## 4. Named markers and bounded delivery

**Agreed v1 contract:** one typed animation-marker notification, carrying a
validated entity handle, marker identity/name, frame, repetition, and clip
identity where applicable, playback identity and a unique occurrence identity
within that playback. The concrete type/tag spelling and identity
representation remain implementation-specification details.

Gameplay handlers interpret the cue and construct any domain events. For
example, an attack's `contact` cue lets gameplay inspect the current target,
weapon and attack validity before emitting a damage-related event; a `footstep`
cue can simply request a sound. The animation does not invent gameplay payloads.

Direct mappings from prefab marker declarations to arbitrary existing custom
GameEvents are outside v1. This is consistent with the named metadata already
produced by AnimationDef and can form a shared marker contract. Validate authored
marker identities and route subscriptions by identity; do not require every
listener to inspect every cue. The identity resolution and retention mechanism
must be specified alongside the event metadata integration.

Acceptance: the full typed payload reaches the intended subscribers, including
the entity/clip distinction for shared marker names; invalid or stale handles
cannot act on replacement entities; a gameplay adapter and a cosmetic handler
demonstrate the two uses. Hooks may perform gameplay actions as well as cosmetic
effects, but must validate the entity and action at delivery. Playback identity
allows rejection of an old attack's cue after interruption. Delivery/backpressure
requirements are below; successful enqueue alone is not successful delivery.

### Agreed crossing semantics

Use chronological crossings, not just the final landed frame. Add examples
and tests for each of these cases before fixing the traversal algorithm:

| Case | Required decision/test |
| --- | --- |
| Frame 0 on start/restart | Emit once at the animation command boundary for playback that starts/restarts after applying the batch. Resume and restoration do not replay it. Intermediate commands superseded in the batch do not emit transient cues. |
| Several crossed markers | Oldest first; stable author order for cues sharing a frame. |
| Loop wrap | Visit the end then the entered start in traversal order, including every crossed loop; record repetition and unique occurrence identity. |
| Once clip | Clamp at final frame; final cue/completion order; no repeated completion on later ticks. |
| Reverse / ping-pong | Emit on every frame entered in traversal order. A turning endpoint is visited once, not again just because direction reverses. |
| Very large dt | Preserve all crossings; process and deliver them in order across updates within a per-update budget. Specify cursor/backpressure mechanics before implementation. |

Crossing accuracy does not promise unlimited delivery. Existing PendingBuf
retains 32 events and AnimationDef traverses at most 512 beats; game enqueue can
also fail allocation. Do not silently reuse those limits while claiming cues
never drop, or replace them with an unbounded catch-up loop.

Agreed policy: retain pending crossings and deliver in order across updates when
the per-update budget is exhausted. Do not silently drop, aggregate or overwrite
pending cues, including on enqueue failure. Retry a failed enqueue without
duplicating an occurrence already successfully handed off. Preserve ordering
across old backlog and newly crossed markers. Coordinate fallible enqueue with
[#856](https://github.com/labelle-toolkit/labelle-engine/issues/856).

This requires a bounded-work/backpressure design, not an unbounded queue or
catch-up loop. Specify numerical limits, resumable traversal cursors and what
advancement does when pending storage cannot grow. Never commit advancement
past a crossing that cannot be retained or reconstructed. Allocation failure
must leave retryable state; report stalls/overload visibly. No implementation
may claim unlimited progress, bounded memory and lossless delivery simultaneously
without a backpressure mechanism. Tests must separate crossing discovery,
successful enqueue, dispatch and save/load handoff.

Interruption does not erase already-crossed markers: keep them with their
original playback identity. Restart/clip replacement creates a new identity;
hooks decide whether the earlier action still applies. Discard a marker if its
target no longer exists, including world/generation invalidation, rather than
retargeting a recycled entity. Define deterministic tie order for markers on
different entities separately from each playback's traversal order.

Keep legacy numeric `event_frames` on its separate landed-on timing path.
It is **not a semantic alias** for crossing-accurate named markers. Changing
legacy timing would require its own explicit migration decision.

## 5. Pause and scaled/unscaled clocks

Do not collapse pause by assigning zero to time scale without specifying the
engine, generated-loop and consumer consequences. The audited behavior is:

- `setPaused(true)` changes the pause flag and emits pause notifications, but
  does not zero `dt * time_scale` in the existing always-run animation pass.
- `setTimeScale(0)` freezes scaled animation but does not emit pause_changed.
- `pause()` followed by `resume_()` replaces a prior scale such as 0.5 with 1.0.
- Root/plugin script ticks are gated on positive scaled dt. Flying Platform's
  Escape-to-resume handler is a normal script tick and would stop running if
  that consumer migrated by simply zeroing time scale.

Agreed clock model: retain the requested game speed separately from explicit
pause and from each animation's speed multiplier:

```text
scaled animation dt = real dt * (game_paused ? 0 : current_game_speed) * animation_speed
unscaled animation dt = real dt * animation_speed
```

Local animation pause suppresses its advancement independently of game pause.
Resume uses the current settings, never restores a stale pre-pause game speed.
For example, animation speed 0.5 multiplied by current game speed 2 gives 1x;
if the game itself changed from 0.5 to 2 while paused, it resumes at 2, not 0.5.
Without an explicit speed change, pause/resume naturally preserves slow motion.
Emit `pause_changed` only on explicit game pause-state transitions. Setting game
speed to zero freezes scaled time without changing that state or emitting a
pause transition. Unscaled animation and UI input continue during game pause.

SpriteAnimation proposes `update: scaled | unscaled`, default scaled. Its
driver already runs before the engine pause return; it needs per-animation
clock selection and gates that allow unscaled instances to progress. An outer
`scaled_dt != 0` gate cannot exclude that work. Move menu/input processing that
must unpause into an always-running path in every affected generated loop.

The animation-only pause API is independent behavior. If retained as a shim,
specify whether it suppresses both update modes or only scaled instances, and
which state implements that suppression. Do not claim subsystem pause state
has disappeared while requiring it through an undocumented compatibility clock.

Acceptance: explicit pause and zero scale; scaled freezing/unscaled progress;
slow-motion restoration; notifications; independent animation suppression;
keyboard and menu unpause; native and callback generated loops. This is a
separate cross-repository migration, not a prerequisite to frame shorthand.

## Consumer pilot and limits

The one-line engine-driver opt-in in Flying Platform is real. The broader
script-removal estimate has not been demonstrated:

- Kitchen and condenser scripts derive activity from current model state.
- Kitchen overlays use spatial room-cell matching, not ancestor matching.
- Disabled-room decoration suppression also uses spatial association.
- Some WC storage-slot entities have no parent link to their room.
- The old `sewer__machine_on/off/pulse` examples are hypothetical events.

Require one real pilot: domain event production, explicit target binding,
stop/idle behavior and load reconciliation, with two independent instances.
Do not claim that roughly half the scripts disappear until this is measured.
Continuous locomotion, stateful door direction and ownership resolution remain
game logic or AnimationDef consumers.

## Readiness and rollout

The investigation's 36 passing tests establish the baseline and its limitations,
not acceptance of any proposed feature. The following checked items record
behavioral decisions agreed in discussion, not implemented delivery.

- [x] Agree top-level `animation/` package alongside `scene/` and `jsonc/`, shared
  game `animations/*.jsonc` definitions and per-entity playback state.
- [x] Agree inclusive frame ranges, explicit zero-padding, load-time expansion,
  reversed/malformed rejection and atlas-ready missing-key diagnostics.
- [x] Choose typed marker notifications for v1; gameplay interprets cues and
  constructs domain events. Direct custom-event mapping is outside v1.
- [x] Agree pause/resume position preservation, stop resetting to frame 0,
  explicit idle-image overrides and visibility remaining independent.
- [x] Agree traversal-order markers, frame-zero start/restart semantics, occurrence
  identity, retained pending crossings and retry without silent loss/duplication.
- [x] Agree retrigger no-op, explicit restart/new playback identity and retention
  of interrupted playback's pending markers; discard invalid entity targets.
- [x] Agree entity/group/broadcast targeting, recipient lifetime, ordered command
  batches, consumption handling and explicit restart synchronization.
- [x] Agree explicit typed payload-to-target mapping without field guessing or
  broadcast fallback, with lifetime checks at dispatch and application.
- [x] Agree saved playback/marker progress, pending cue preservation with entity
  remapping, no historical marker replay, and post-restore game reconciliation.
- [x] Agree independent pause and speed settings, scaled/unscaled clocks, current
  speed on resume, explicit-only pause notifications and always-running UI input.
- [x] Choose compatibility diagnostics followed by major-release default driving,
  with explicit manual opt-out and exactly one owner of advancement.
- [ ] Specify concrete JSONC schema, grammar limits, package dependency wiring,
  typed adapter APIs, binding/state layout and remaining mode-change semantics.
- [ ] Specify bounded storage/traversal backpressure and atomic save/queue handoff,
  cross-entity tie ordering, and hot-reload identity/lifetime details.
- [ ] Implement/test native and callback loop integration, consumption ordering,
  unscaled input migration and compatibility shims; verify single advancement.
- [ ] Demonstrate a real consumer pilot, including persistence and failure paths.

Recommended implementation order: shorthand; marker contract; triggers with a
consumer pilot; pause migration; default driving. Each has its own acceptance
gate. The marker and trigger work shares the hooks delivery/ordering contracts;
the whole hooks enhancement roadmap is not a prerequisite to start shorthand.
