# RFC: Declarative, event-driven sprite animation

## Status and scope

**Design revision, not an implemented API or an approved implementation plan.**
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

The frame shorthand is closest to implementation. The event bridge, playback
state, dispatch schedule, targeting and pause migration require the decisions
listed below before their implementation PRs start. Publishing this RFC does
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

Choose the release mechanism before implementation: an explicit project
configuration/default for new projects, or a documented engine default change
with consumer migration. The assembler, generated loops and engine flag must
agree. The no-animation path should remain inexpensive; this RFC makes no
unmeasured zero-cost claim.

Acceptance: exactly one advance per frame, manual-driver opt-out, the migrated
Flying Platform setup, and a project without SpriteAnimation. Default-on is a
separate rollout gate from frame-pattern support.

## 2. Frame-range shorthand

Illustrative authoring syntax, subject to the validation contract below:

```jsonc
"SpriteAnimation": {
  "frames_pattern": "sewer/sewer_machine/sewer_machine_%04d.png",
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

The implementation specification must settle:

- Inclusive bounds; supported integer placeholder and zero-padding grammar;
  width limits; malformed, reversed and empty ranges.
- Checked arithmetic before allocating, and the current 255-frame ceiling.
- Explicit-list/pattern conflict handling. The old proposal silently preferred
  `frames`; the recommended rule is a diagnostic when both are authored.
- Syntax diagnostics versus resource readiness. Validate keys when the atlas
  becomes available; an asynchronously loading atlas is not a malformed key.
- Ownership: the expanded slice belongs to the per-world arena; strings use
  the existing intern mechanism. No borrows from temporary parsed JSON and no
  permanent slice allocation on every prefab respawn.

Acceptance: equivalence with an explicit list; first/last frames; range and
allocation boundaries; extensionless keys; missing-frame diagnostics; repeated
spawn/reset lifetime; representative root and pack prefabs.

## 3. Scoped event-triggered playback

The proposed surface remains declarative. These event names are illustrative
domain events, not existing Flying Platform events:

```jsonc
"SpriteAnimation": {
  "frames_pattern": "machine_%04d.png", "from": 1, "to": 10,
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

Self/owner-scoped matching is the recommended default; broadcast requires an
explicit `scope: "any"`. This is not yet a complete target contract:

- Specify target extraction from typed payload metadata. An arbitrary `entity`
  field can mean an actor/source, and many events have no entity field.
- For an untargeted event, require explicit broadcast or a declared adapter;
  never silently interpret it as “all instances” under self scope.
- Define whether self means exact entity, ancestors, or a declared owner
  binding; define deterministic matching and invalid/cyclic ancestry handling.
- Validate entity lifetime at delivery and command application. Reset/destroy
  must invalidate queued targets; bare recycled IDs must not target a new entity.
- For spatially associated props, domain code supplies the target binding.
  Kitchen overlays currently use room cells; not all relationships are parents.

Choose the component boundary before implementation: fields on SpriteAnimation
or a sibling binding component. A first version restricted to SpriteAnimation
is recommended. AnimationDef reuse needs an explicit def/clip binding; existing
transition tables alone do not identify which game component to control.

### Playback state and repeated requests

Define playing, paused, stopped/dormant and completed states, with this action
table completed as part of the implementation specification:

| Request | Contract to specify |
| --- | --- |
| `play: once/loop/ping_pong` | Which state resets; mode changes; repeated requests. Recommended: repeated running loop is a no-op, once restarts. |
| `stop` | Hold current image or restore an idle/initial frame; timer/direction/repetition reset. Current consumers sometimes explicitly restore idle. |
| `pause` / `resume` | Preserve playback position; define resume from stopped/completed; interaction with global and subsystem pause. |
| `restart` | Reset frame, timer, direction, repetition and marker cursor; update the visible sprite even without a later frame crossing. |
| `start: dormant` | Initial visible frame and behavior before the first request; reconciliation after loading. |

Reject conflicting `play` and `action` fields in one entry. Specify ordering
for multiple matching entries and multiple events in one drain. Address speed
zero, mode changes, completion, and frame-zero entry cues explicitly.

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

Recommended integration: a dispatch listener queues animation commands, and a
defined animation boundary applies them. Settle that boundary and whether a
play request displays frame zero immediately or on the next update. Preserve
once-per-drain delivery and the next-drain behavior of handler-emitted events.

Specify ordering relative to native/flow listeners and consumable events. A
buffer tap observes even events later consumed; a normal listener may not.
The RFC must choose rather than accidentally inherit one behavior. Coordinate
with [delivery contracts #857](https://github.com/labelle-toolkit/labelle-engine/issues/857)
and [handler ordering](https://github.com/labelle-toolkit/labelle-assembler/issues/723).

Never execute arbitrary gameplay callbacks while an animation ECS view/pointer
is live. Marker-trigger cycles must not recursively drain or advance forever
in one frame. Bound pending commands and define visible overflow reporting.

### Load and state reconciliation

SpriteAnimation is transient. An already-active machine restored from a save
may never emit a new “on” edge. Choose a post-restoration reconciliation step
or a domain synchronization event with explicit target binding. Entity-ready
callbacks are not a whole-scene completion guarantee.

Acceptance: two independently targeted props; explicit broadcast; missing or
invalid targets; sync/buffered events; repeated/conflicting commands; deletion
and world reset; restart visibility; an active prop restored without a new edge.

## 4. Named markers and bounded delivery

Named markers should identify a cue and the animation that crossed it. The
original arbitrary `emit: "footstep"` promise requires a typed-event bridge:

1. **Recommended first contract:** a typed engine marker notification carrying
   entity, marker name, frame and repetition. Consumers filter the cue name.
2. **Alternative:** a generated mapping to existing GameEvents variants, with
   required payload validation or an explicit payload adapter. A marker entity
   alone cannot populate arbitrary event fields.

Choose one before coding. A generic named cue is not an implementation of
arbitrary custom event emission. It is consistent with the named metadata
AnimationDef already produces and can form a shared marker contract.

### Crossing semantics to pin down

Use chronological crossings, not just the final landed frame. Add examples
and tests for each of these cases before fixing the traversal algorithm:

| Case | Required decision/test |
| --- | --- |
| Frame 0 on start/restart | Does it emit on command application or first positive advance? Exactly once for the chosen boundary. |
| Several crossed markers | Oldest first; stable author order for cues sharing a frame. |
| Loop wrap | End/start ordering; repeated hits across multiple loops; repetition attribution. |
| Once clip | Clamp at final frame; final cue/completion order; no repeated completion on later ticks. |
| Ping-pong | Forward/backward order and endpoint visitation; avoid double-counting an endpoint on reversal. |
| Very large dt | Bounded work, accurate final playback state, observable excess delivery. |

Crossing accuracy does not promise unlimited delivery. Existing PendingBuf
retains 32 events and AnimationDef traverses at most 512 beats; game enqueue can
also fail allocation. Do not silently reuse those limits while claiming cues
never drop, or replace them with an unbounded catch-up loop.

The preferred requirement is exact delivery within a documented budget with
explicit overflow/failure reporting. Specify whether excess cosmetic cues may
be aggregated or discarded, and how an authoritative consumer reconciles.
Coordinate enqueue reporting with [#856](https://github.com/labelle-toolkit/labelle-engine/issues/856).
Tests must distinguish correct traversal from successful downstream enqueue.

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

Recommended clock model: retain configured time scale, derive effective scaled
dt from explicit pause, and expose real/unscaled dt separately. Preserve a
slow-motion setting across pause/resume. Specify whether pause notifications
describe explicit pause transitions, the effective frozen state, or both.

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
not acceptance of any proposed feature. The PR remains a design discussion.

- [ ] Finalize shorthand grammar, bounds, ownership and diagnostics.
- [ ] Choose generic marker notification versus typed custom-event mapping.
- [ ] Specify crossing order and bounded delivery/failure behavior.
- [ ] Choose trigger component/state layout, target contract and dispatch phase.
- [ ] Define reconciliation and demonstrate a real consumer pilot.
- [ ] Specify effective clocks, pause notifications and unscaled input migration.
- [ ] Choose the default-driving rollout and verify single ownership.

Recommended implementation order: shorthand; marker contract; triggers with a
consumer pilot; pause migration; default driving. Each has its own acceptance
gate. The marker and trigger work shares the hooks delivery/ordering contracts;
the whole hooks enhancement roadmap is not a prerequisite to start shorthand.
