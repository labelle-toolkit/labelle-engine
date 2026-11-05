# RFC: Declarative, event-driven sprite animation

## Status and scope

**Agreed behavioral design; first two stages shipped, the rest outstanding.**
The September 9 investigation checked the then-current engine, assembler, core
and Flying Platform code, all 17 PR review threads, and 36 focused tests. See the
[investigation and review dispositions](docs/investigations/rfc-793/investigation.md)
and [reproducible probes](docs/investigations/rfc-793/README.md). That record
describes engine `46677c9` (v2.18.0); the "current baseline" below has been
re-verified against engine `main` at `be0991e` (v4.1.1).

Since the investigation, three engine PRs landed the first implementation stages:
[#870](https://github.com/labelle-toolkit/labelle-engine/pull/870) (standalone
`animation/` definition package), [#871](https://github.com/labelle-toolkit/labelle-engine/pull/871)
(prefab binding to shared JSONC definitions) and
[#872](https://github.com/labelle-toolkit/labelle-engine/pull/872) (package
consolidation and named-marker delivery). Their shipped contracts are documented in
`animation/README.md` and `animation/MARKERS.md`; this RFC records where they
satisfy, narrow or leave open the agreed design.

Five workstreams make animation authoring simpler:

1. Drive SpriteAnimation by default, with one owner of advancement.
2. Expand frame ranges from authored patterns.
3. Start, stop and control playback from scoped events.
4. Emit named, crossing-accurate frame cues with an explicit delivery policy.
5. Define scaled/unscaled animation clocks and migrate pause behavior.

The September 10 design discussion agreed the package boundary, JSONC authoring,
targeting, dispatch, retriggering, marker crossings and pending delivery,
save/load continuity, clocks and default-driving migration recorded below.
Workstreams 2 and 4 now have shipped schema, limits and engine integration
(see each section). Triggers (3), clocks (5), default driving (1) and
persistence still need implementation specifications and validation.
Publishing this RFC does not close
[#794](https://github.com/labelle-toolkit/labelle-engine/issues/794).

## Motivation and current baseline

Simple animated props should be authorable as prefab data. Continuous character
state, room ownership and gameplay decisions remain the game's responsibility.
The target is less repeated playback code, not a second game state machine.

Investigation baseline: engine `46677c9` (v2.18.0), assembler `cabe371`, core
`5425b7c`; full revisions and source links are in the investigation. The
original RFC branch predated the `46677c9` foundation and was merged up to that
v2.18.0 baseline (`fc772f0`). The claims below have since been re-checked and
updated in this document against engine `main` `be0991e` (v4.1.1, which
includes #870–#872), although the branch working tree itself has not yet been
rebased onto `be0991e`; assembler, core and Flying Platform revisions were not
re-checked in this pass.

- `SpriteAnimation` (now `animation/src/sprite_animation.zig`) has frames, fps,
  boundary mode, per-clip speed and numeric `event_frames`. Since #871/#872 it
  also carries `definition`/`clip` references, borrowed `markers`, a
  `MarkerCursor`, and `marker_target_id`/`marker_playback_id` identities. The
  component is still transient (`save_policy.Saveable(.transient)`); prefab
  loading recreates it and resets playback state. The frame-count limit is 255
  (`frame` is `u8`; `FrameRange.max_frames = 255`; binding rejects larger lists).
- The engine's `game/loop_mixin.zig` advances it when `drive_sprite_animations`
  is enabled. The flag still defaults to false (`src/game.zig`), and
  `setDriveSpriteAnimations` documents that a game must not also run its own
  `sprite_animation_tick` script.
- The driver emits buffered `engine__anim_frame`, `engine__anim_complete` and
  `engine__anim_loop` events. Legacy numeric frame cues fire when a tick lands
  on a marked frame; they can miss crossings. Since #872 clips with named
  markers take a separate crossing-accurate path (`src/named_animation_tick.zig`)
  that emits `engine__anim_marker`; numeric cues keep their landed-on timing.
- `AnimationDef` (now in the animation package) has named marker metadata,
  crossing traversal and `TransitionRule` tables. Those facilities are reusable,
  but their output is not a generic runtime-string-to-GameEvents emitter.
- `game.emit` accepts a typed union value and swallows enqueue failure.
  `tryEmit` (#856) returns the enqueue error with the buffer unchanged.
  `emitEngineEvent` requires a comptime tag and a compatible payload and folds
  to a no-op when the project's `GameEvents` lacks the variant. `emitSync`
  bypasses the buffer. The named-marker tick uses `tryEmit`.
- The legacy `PendingBuf` retains at most 32 events and legacy AnimationDef
  traversal is bounded to 512 crossed beats; overflow there is still discarded.
  The new `MarkerCursor` is allocation-free with a per-update budget of 256
  entered frames and 64 event handoffs, and stalls the clock instead of dropping.
- Explicit pause and zero time scale are different paths. The sprite-animation
  tick lives in the always-run block before the engine's `isPaused()` return
  and receives `scaled_dt`, or `0` when `sprite_animations_paused` is set; a
  zero-delta pass still runs to synchronize a newly bound frame zero and finish
  pending marker handoffs. `setPaused(true)` does not zero `time_scale`, so it
  freezes the gameplay clock while sprites still advance.

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
`src/animation/` directory. This shipped in #870–#872 (`animation/` v0.2.0):

```text
labelle-engine/
  animation/
    build.zig
    build.zig.zon       # depends on ../jsonc and labelle-core only
    README.md
    MARKERS.md
    src/                # Definition, FrameRange, Library, Marker, MarkerCursor,
                        # plus the moved AnimationDef/AnimationState/SpriteAnimation
    test/
  scene/
  jsonc/
  src/                  # engine integration (ticks, binding, hook delivery)
```

The package owns definitions, JSONC parsing/validation, playback, and marker
mechanics. Engine-specific ECS, event-dispatch, persistence and game-loop
adapters stay in engine `src/` (`game/animation_runtime_mixin.zig`,
`sprite_animation_tick.zig`, `named_animation_tick.zig`,
`jsonc/component_apply.zig`). The package does not import the engine; the engine
imports it as the `animation` module and re-exports the public types through
`src/root.zig`, so `engine.SpriteAnimation`, `engine.AnimationDef` and friends
are preserved. The legacy AnimationDef foundation was moved into the package
rather than duplicated. Its own `zig build test` (in `animation/build.zig`)
runs the 9 engine-independent suites, including `definition_test.zig` and
`marker_test.zig`. At the engine root, `zig build test-animation` runs only the
definition-to-engine compatibility tests in
`animation/test/animation_package_test.zig`; `zig build test-animation-legacy`
(and the root `zig build test`) runs `animation_package_test.zig` plus the 12
legacy/engine-adapter test files listed in `build.zig`'s `test_files`, which
excludes `definition_test.zig` and `marker_test.zig` (CI runs `cd animation &&
zig build test` separately in `.github/workflows/ci.yml`).

Still open in this boundary: trigger-command mechanics and definition
reload/reconciliation. `Library.load` rejects a duplicate name and there is no
live-replacement API yet.

Games author shared definitions in `animations/*.jsonc`. The shipped `version: 1`
schema holds named clips with either `frames` or `frames_pattern`/`from`/`to`,
plus optional `markers`. Default speed and clip transitions are **not** accepted
yet (unknown fields fail definition load). Prefabs refer to a definition and a
clip and choose per-instance `fps`, `mode` and `speed`; each entity owns separate
playback state. This is the shipped prefab form:

```jsonc
"SpriteAnimation": {
  "definition": "animations/wc_door.jsonc",
  "clip": "closed",
  "fps": 8, "mode": "loop"
}
```

Combining inline `frames` with `definition` is rejected (`AmbiguousAnimationFrames`);
`clip` without `definition` and `markers` without `definition` are rejected too.
Event/target bindings that depend on the prefab remain unspecified (section 3).

The engine registers sources through `game.loadAnimationJsoncSource(name, source)`
before scenes load; the assembler side that discovers and embeds `animations/`
is described in `animation/README.md` as the integration contract and was not
re-verified in this pass. The session-owned `Library` keeps names and frame
tables alive until game deinit, so shared definition lifetimes cover playback
and queued marker strings across scene reset. Hot reload/live replacement is
still unimplemented. `.zon` `AnimationDef` files keep their existing
interpretation unchanged.

### Expansion contract

Shipped authoring syntax lives in the definition file, not inline on the
prefab component:

```jsonc
{
  "version": 1,
  "clips": {
    "run": {
      "frames_pattern": "sewer/sewer_machine/sewer_machine_{frame:04}.png",
      "from": 1, "to": 10
    }
  }
}
```

`Definition.parse` expands the pattern into the same frame-key slice an
explicit `frames` list produces, so `SpriteAnimation` sees one representation.
Inline `frames_pattern` on the prefab component is not supported, but it is
not rejected either: the engine's struct deserializer
(`src/jsonc/deserializer.zig`, `deserializeStruct`) looks up each struct field
by name and has no branch for JSON keys that match no field, so an unknown key
such as `frames_pattern`, `from` or `to` is silently ignored. The component then
reaches `bindSpriteAnimation` with empty `frames` and `definition` and fails
with `InvalidAnimationFrames`, a diagnostic that does not name the real
mistake. The same walk populates every struct field, including runtime state
(`frame`, `timer`, `marker_target_id`, `marker_playback_id`, `marker_cursor`),
not only the authoring fields. The earlier inline-pattern proposal is
superseded by the definition-file form; an unknown-key diagnostic for this
component is an open acceptance item (see section 3 and the readiness list).

Runtime-only fields are a second, sharper form of the same gap. The walk also
accepts `forward`, `finished_emitted`, `repetition`, `definition_dirty`,
`definition_validated` and `marker_stalled`, and the inline branch of
`bindSpriteAnimation` returns without resetting any of them
(`src/game/animation_runtime_mixin.zig:79-85`). Authoring
`definition_dirty: true` with an out-of-range `frame` therefore reaches
`currentSprite()`'s unchecked `frames[self.frame]`
(`animation/src/sprite_animation.zig:350-352`, consumed at
`src/sprite_animation_tick.zig:110-114`) and can index out of bounds; a large
authored `timer` reaches the unchecked `@intFromFloat` into `u32` in `advance`
(`animation/src/sprite_animation.zig:214`). Runtime-only state must be rejected
or reset on bind before prefab authoring is considered closed.

`markers` are also not a supported inline prefab field. With `definition` set
they are overwritten from the clip, but when marker/lifecycle events are wanted
a nonempty authored `markers` list fails the pending-cursor check because the
freshly defaulted `MarkerCursor` already has `entering = true`
(`src/game/animation_runtime_mixin.zig:78`,
`animation/src/marker_cursor.zig:32,47-48`); without those events the authored
list is silently ignored. Inline `markers` must be rejected explicitly, not
interpreted.

Frame keys are exact atlas identifiers. No implicit `.png` suffix: extensionless
grid keys such as `tiles/0` are also valid. Authors include any desired extension
in the pattern. Preserve explicit `frames` support.

Shipped expansion behavior (`animation/src/frame_range.zig`,
`animation/src/definition.zig`):

- Expansion happens at definition load. `from`/`to` are unsigned 32-bit,
  inclusive, ascending; a single-frame range is valid; a reversed range fails
  (`ReversedRange`). Exactly one `{frame}` or `{frame:0N}` placeholder with
  `N` from 1 through 10; padding never truncates a wider number. Reverse
  playback uses direction, not reversed authoring bounds.
- Frame count is checked against the 255 ceiling before allocating
  (`TooManyFrames`); key sizes use checked arithmetic.
- Authoring `frames` together with any of `frames_pattern`/`from`/`to` fails
  (`ConflictingFrames`); the old silent preference for `frames` is gone.
- Parse success means structurally valid authoring, not resource availability.
  `Definition.firstMissingFrame` and `game.validateSpriteAnimation` check keys
  once atlases are resident; the automatic check
  (`validateSceneSpriteAnimations`) runs after the current scene's asset
  manifest is ready, logs definition, clip, frame index and missing key once,
  and stops the invalid clip by setting its `speed` to 0. Without a nonempty
  scene manifest, the host owns the readiness boundary. The automatic check
  only visits definition-bound components: it skips `anim.definition.len == 0`
  (`src/game/animation_runtime_mixin.zig:162`), so inline `frames` are never
  automatically validated or stopped; a host using inline frames must call
  `validateSpriteAnimation` itself. Note that
  `validateSceneSpriteAnimations` is currently called from
  `AtlasMixin.resolveAtlasSprites` (`src/game/atlas_mixin.zig`), which runs in
  `Game.tick` *after* `sprite_animation_tick.tick` (`src/game/loop_mixin.zig`)
  and is skipped on non-atlas renderers (`!has_atlas_sprite_fields`), so an
  invalid clip still executes one animation tick (updating `Sprite.sprite_name`
  and queuing any frame-0/first-tick markers) before `speed` is zeroed.
- Expanded slices belong to the definition's arena, owned by the session
  `Library`; prefab respawn rebinds borrowed slices without re-expanding.

Remaining: hot reload of a loaded definition, pack-local discovery, and the
assembler-side embedding path are not implemented or verified here.

Acceptance (covered by `animation/test/definition_test.zig`,
`animation/test/animation_package_test.zig`): equivalence with an explicit list;
first/last frames; range and allocation boundaries; extensionless keys;
missing-frame diagnostics; repeated spawn/reset lifetime. Still outstanding:
representative root and pack prefabs in an assembled game.

## 3. Scoped event-triggered playback

The proposed surface remains declarative. These event names are illustrative
domain events, not existing Flying Platform events:

```jsonc
"SpriteAnimation": {
  "definition": "animations/factory_machine.jsonc", "clip": "run",
  "fps": 8, "start": "dormant",
  "triggers": [
    { "on": "factory.machine_on", "play": "loop" },
    { "on": "factory.machine_off", "action": "stop" }
  ]
}
```

None of this trigger surface is implemented on main as of `be0991e`; the
`animation/` package has no trigger schema and `Definition.parse` rejects a
`triggers` field inside a definition file. On the prefab component, however,
`start` and `triggers` are today silently ignored by the struct deserializer
(section 2, "Expansion contract"): a prefab authored against this proposal
loads without error and simply never reacts. Trigger rollout must therefore
ship an unknown-key diagnostic for `SpriteAnimation` (engine deserializer or
assembler validation) so pre-rollout authoring fails closed, and acceptance
must include that case.

Playback control today is imperative:
`game.selectSpriteAnimation(anim, definition, clip)` rebinds a clip atomically
and returns `PendingAnimationMarkers` while `anim.markers.len != 0` and
`anim.marker_cursor.pending()` is true (`src/game/animation_runtime_mixin.zig`,
`bindSpriteAnimation`). Two cursor details constrain the trigger batch design:

1. `MarkerCursor` initializes with `entering: bool = true` and
   `pump_started: bool = false` (`animation/src/marker_cursor.zig`). Unlike
   `MarkerCursor.offer`, which checks `(self.entering and self.pump_started)`,
   `MarkerCursor.pending()` returns `true` whenever `self.entering` is set—even
   before the first tick has run and even when frame 0 has no markers. A
   freshly bound marked clip therefore fails `selectSpriteAnimation` (and
   prefab refresh) with `PendingAnimationMarkers` until a tick pumps frame 0
   (`animation/test/animation_package_test.zig`). Applying a multi-command
   batch (`play(A) -> play(B)` or `restart -> stop`), or rebinding on the spawn
   frame before the first tick, requires allowing replacement of an unpumped
   initial cursor without emitting transient cues.
2. When a target has genuinely crossed markers that have not yet drained from
   `MarkerCursor`, `bindSpriteAnimation` refuses and leaves the old player
   intact, so the batch contract must choose whether a queued `play`/`restart`
   stalls/retries or drains-then-rebinds. That decision is still open.

### Event identity and typed payloads

Validate `on` against discovered event metadata. Dotted provider/event names
are the recommended author spelling; current assembler retention also accepts
qualified `provider__event` spelling in JSONC (assembler-side behavior from the
investigation, not re-verified in this pass). Specify alias and pack-namespace
resolution once and reuse it for validation, code generation and inspection.
Unknown names must produce actionable diagnostics.

The existing consumption filter scans JSON/JSONC for both spellings
(assembler-side, not re-verified here). Reuse it;
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
is recommended. SpriteAnimation now carries `definition`/`clip` references, so
a def/clip binding exists for that component; AnimationDef reuse still needs
its own explicit binding, because transition tables alone do not identify which
game component to control.

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
Stop is a reset-to-stopped action, not a new playback start. Note that today a
zero-delta tick (`dt == 0` or `speed <= 0`) sets `budget.frames = 0` in
`src/named_animation_tick.zig` and still calls `MarkerCursor.pump`, which drains
`self.entering` (and `complete_pending` on a 1-frame `.once` clip) before
checking `budget.frames` (`animation/src/marker_cursor.zig`); an entity spawned
with `speed = 0` therefore still emits its frame-0 markers on the first tick
(`animation/test/animation_package_test.zig`). Implementing `start: "dormant"`
and `stop` cannot merely reset `MarkerCursor{}` with `speed = 0`; stopped and
dormant states must suppress `entering` until playback starts.

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
engine-tick events (including every `engine__anim_*` event) reach the next
iteration's drain. Synchronous events never enter that buffer. This order is
now recorded for every shipped backend template in `HOOK-DELIVERY-CONTRACT.md`
§2 (#857), which is the reference to cite rather than re-deriving it here.

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

The current SpriteAnimation is transient, and #872 explicitly leaves it so
(`animation/MARKERS.md`, "Scope still outstanding"); the agreed design adds
persistence where continuity matters. Note that live prefab reload
(`src/jsonc/scene_loader/prefab_refresh.zig`) currently refreshes
`SpriteAnimation` only because `getSavePolicy(SpriteAnimation) == .transient`;
changing its save policy to `.saveable` will silently exclude it from
`PrefabRefresh` unless the refresh path is updated alongside persistence.

Nor is persistence a save-policy flip alone. `SpriteAnimation.frames` is a
slice-of-slice the serializer does not write, and `definition`/`clip`/`markers`
are borrowed string and struct slices (`animation/src/sprite_animation.zig:52-64`;
`src/game/save_load/save.zig:25-31`). A persisted representation must define
which fields are skipped and re-derived from `definition`/`clip` on restore,
plus a load-time rebind, before `.saveable` can replace `.transient`.
Save clip, playback position and residual time,
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

**Agreed v1 contract, shipped in #872:** one typed animation-marker
notification, `engine__anim_marker`, declared on `engine.Events`
(`src/root.zig`) with payload `entity`, `target_id`, `playback_id`, `sequence`,
`definition`, `clip`, `marker`, `marker_index`, `frame` and `repetition`.
`target_id` identifies the animation attachment. Identities come from a
per-game counter (`nextAnimationIdentity`) that ECS/world resets do not touch,
so an id is never reused and a cue whose attachment was destroyed or reset is
dropped rather than retargeted; `playback_id` changes on every clip selection;
`sequence` is unique within a playback. The engine drops a queued `engine__anim_marker` cue at native/flow hook
delivery (`src/game/events_mixin.zig`, `deliver`) when
`game.isAnimationMarkerTargetAlive` fails, and hooks must recheck it before
acting. Two delivery gaps remain: `engine.script_contract.drainEvents`
(`src/script_contract.zig`) taps `g.event_buffer` before `dispatchEvents`
without checking `isAnimationMarkerTargetAlive`, so language-script subscribers
can still receive a stale marker; and on marked clips,
`src/named_animation_tick.zig` routes `engine__anim_complete` and
`engine__anim_loop` through the same `MarkerCursor` and `tryEmit` path (sharing
the 64-event budget and `PendingAnimationMarkers` guard), but their payloads
(`src/root.zig`) still carry `entity: u32` without `target_id` or `playback_id`
and are not filtered at delivery.

Those gaps are scoped to `engine__anim_marker` and cursor-routed lifecycle
occurrences. The legacy `engine__anim_frame` payload and the legacy
`engine__anim_complete`/`engine__anim_loop` path for clips without markers also
carry bare `entity` (no `target_id`/`playback_id`) and are not liveness-filtered
(`src/root.zig:487-521`, `src/sprite_animation_tick.zig:132-141`). v1 must state
whether those legacy cues are explicitly outside the identity contract or must
gain the same tokens.

Gap: `marker_target_id` and `marker_playback_id` are ordinary struct fields,
so the prefab deserializer accepts them from JSONC, and `bindSpriteAnimation`
keeps a nonzero authored `marker_target_id` instead of allocating one
(`animation_runtime_mixin.zig`, `if (anim.marker_target_id == 0)`). Two
prefabs authoring the same value, or a prefab reusing a value from a destroyed
entity, weaken the reuse guard. `animation/MARKERS.md` only advises against
copying identity fields. The contract must make identity fields
non-authorable (reject or ignore them at load) before persistence stores them.

Marker authoring: `markers: [{ "name", "frame" }]` per clip, zero-based
frame indices, unique nonempty names per clip, at most 256 per clip, authored
order kept for equal frames.

Gameplay handlers interpret the cue and construct any domain events. For
example, an attack's `contact` cue lets gameplay inspect the current target,
weapon and attack validity before emitting a damage-related event; a `footstep`
cue can simply request a sound. The animation does not invent gameplay payloads.

Direct mappings from prefab marker declarations to arbitrary existing custom
GameEvents are outside v1. This is consistent with the named metadata already
produced by AnimationDef and can form a shared marker contract. Still open:
marker-specific subscriber indexes, so listeners are not required to inspect
every cue; today every `engine__anim_marker` subscriber receives every cue. The
identity resolution and retention mechanism must be specified alongside the
event metadata integration.

Acceptance: the full typed payload reaches the intended subscribers, including
the entity/clip distinction for shared marker names; invalid or stale handles
cannot act on replacement entities; a gameplay adapter and a cosmetic handler
demonstrate the two uses. Hooks may perform gameplay actions as well as cosmetic
effects, but must validate the entity and action at delivery. Playback identity
allows rejection of an old attack's cue after interruption. Delivery/backpressure
requirements are below; successful enqueue alone is not successful delivery.

### Agreed crossing semantics

Use chronological crossings, not just the final landed frame. The
`MarkerCursor` traversal in #872 implements these cases and
`animation/test/marker_test.zig` covers them. The cursor implements the
traversal cases (frame-zero entry, ordering, loop/once/ping-pong, budgets); the
command-boundary rules, superseded-intermediate suppression and persistence
restoration in the frame-zero row remain trigger/persistence work. The table
below remains the contract any later change must keep:

| Case | Required decision/test |
| --- | --- |
| Frame 0 on start/restart | Emit once at the animation command boundary for playback that starts/restarts after applying the batch. Resume and restoration do not replay it. Intermediate commands superseded in the batch do not emit transient cues. |
| Several crossed markers | Oldest first; stable author order for cues sharing a frame. |
| Loop wrap | Visit the end then the entered start in traversal order, including every crossed loop; record repetition and unique occurrence identity. |
| Once clip | Clamp at final frame; final cue/completion order; no repeated completion on later ticks. |
| Reverse / ping-pong | Emit on every frame entered in traversal order. A turning endpoint is visited once, not again just because direction reverses. |
| Very large dt | Preserve all crossings; process and deliver them in order across updates within a per-update budget (cursor/backpressure mechanics shipped below). |

Crossing accuracy does not promise unlimited delivery. The legacy
`SpriteAnimation` numeric path uses the 32-event `PendingBuf`; the separate
`AnimationDef` beat traversal is capped at 512 beats; game enqueue can also fail
allocation. On a clip with named markers the numeric `engine__anim_frame` cue is
emitted directly (`src/sprite_animation_tick.zig:99-107`), so the 32-event cap
does not bound it. The named-marker path reuses neither limit.

Agreed policy, implemented in #872: retain pending crossings and deliver in
order across updates when the per-update budget is exhausted. Do not silently
drop, aggregate or overwrite pending cues, including on enqueue failure. Retry
a failed enqueue without duplicating an occurrence already successfully handed
off. Preserve ordering across old backlog and newly crossed markers. Fallible
enqueue is `tryEmit`
([#856](https://github.com/labelle-toolkit/labelle-engine/issues/856),
`rfc/EVENTS-FALLIBLE-ENQUEUE.md`); the cursor advances `sequence` only after a
successful `tryEmit`.

Shipped backpressure numbers (`animation/src/marker_cursor.zig`,
`src/named_animation_tick.zig`): per entity per update, at most 256 entered
frames and 64 event handoffs, shared between old backlog and new elapsed time;
one offered batch must hold fewer than 2^32 beats; invalid or excessive time
fails without mutating the cursor. When old work cannot drain, the animation
clock stalls and new wall time is not accepted; the first stalled update logs a
warning and recovery re-arms it. Unrequested occurrence kinds consume neither
handoffs nor sequence identities. Clips without markers, or games that request
neither `engine__anim_marker` nor lifecycle events, keep the legacy catch-up
behavior. The normal game event queue remains dynamically allocated, so this
bounds producer work and cursor memory, not total memory when a game never
drains. Successful enqueue is not acknowledgement of handler execution.

Tests separate crossing discovery, failed queue handoff, ordinary hook
delivery, attachment invalidation on ECS reset and pause/backpressure
(`animation/test/marker_test.zig`, `animation/test/animation_package_test.zig`).
Save/load handoff tests remain outstanding with persistence itself.

Interruption does not erase already-crossed markers: keep them with their
original playback identity. Restart/clip replacement creates a new identity;
hooks decide whether the earlier action still applies. Discard a marker if its
target no longer exists, including world/generation invalidation, rather than
retargeting a recycled entity. These three rules are implemented
(`selectSpriteAnimation`, `isAnimationMarkerTargetAlive`, prefab refresh
deferral while a cursor is pending). Cross-entity order is currently ECS
traversal order with no timestamp sort; a deterministic, backend-independent
tie order for markers on different entities is still to be defined.

Keep legacy numeric `event_frames` on its separate landed-on timing path.
It is **not a semantic alias** for crossing-accurate named markers. #872 keeps
that split: on a clip with named markers, `engine__anim_frame` still fires only
when the frame actually changed to a listed index. Changing legacy timing would
require its own explicit migration decision.

## 5. Pause and scaled/unscaled clocks

Do not collapse pause by assigning zero to time scale without specifying the
engine, generated-loop and consumer consequences. The audited behavior is:

- `setPaused(true)` changes the pause flag and emits `pause_changed` plus
  `engine__pause_changed`, but does not zero `time_scale`, so the always-run
  animation pass still receives `scaled_dt` (nonzero whenever `time_scale` is
  nonzero).
- `setTimeScale(0)` freezes scaled animation and the gameplay clock but does
  not emit `pause_changed`. `isPaused()` is true under either path.
- `pause()` sets `time_scale = 0` and `setPaused(true)`; `resume_()` sets
  `time_scale = 1.0`, replacing a prior scale such as 0.5.
- Root/plugin script ticks are gated on positive scaled dt in every shipped
  generated loop (`HOOK-DELIVERY-CONTRACT.md` §2). Flying Platform's
  Escape-to-resume handler is a normal script tick and would stop running if
  that consumer migrated by simply zeroing time scale (not re-verified here).
- `setSpriteAnimationsPaused(true)` is a third, animation-only pause: the tick
  still runs with `dt = 0`, which freezes clocks and deferred beats but lets an
  already-entered frame finish its marker handoff.

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

The animation-only pause API (`sprite_animations_paused`) is independent
behavior. If retained as a shim, specify whether it suppresses both update
modes or only scaled instances, and which state implements that suppression.
Do not claim subsystem pause state has disappeared while requiring it through
an undocumented compatibility clock. Nothing in this section is implemented on
main; an `update` key on the component is silently ignored by the struct
deserializer today, not rejected (section 2, "Expansion contract"), so the
rollout needs the same unknown-key diagnostic as triggers.

Acceptance: explicit pause and zero scale; scaled freezing/unscaled progress;
slow-motion restoration; notifications; independent animation suppression;
keyboard and menu unpause; native and callback generated loops. This is a
separate cross-repository migration, not a prerequisite to frame shorthand.

## Consumer pilot and limits

The one-line engine-driver opt-in in Flying Platform is real, and
`animation/MARKERS.md` reports a Flying Platform probe with one running and
one paused propeller driving the generated loop and a typed `HookContext`
receiver (not re-verified in this pass). The broader script-removal estimate
has not been demonstrated:

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
not acceptance of any proposed feature. The checked items below record
behavioral decisions agreed in discussion. Where a decision has since shipped,
the item says so; everything else is agreement, not delivery.

- [x] Agree top-level `animation/` package alongside `scene/` and `jsonc/`, shared
  game `animations/*.jsonc` definitions and per-entity playback state.
  Shipped in #870–#872 (`animation/` v0.2.0, `Library`, prefab binding).
- [x] Agree inclusive frame ranges, explicit zero-padding, load-time expansion,
  reversed/malformed rejection and atlas-ready missing-key diagnostics.
  Shipped in #870/#871 (`FrameRange`, `Definition.parse`, `validateSpriteAnimation`).
- [x] Choose typed marker notifications for v1; gameplay interprets cues and
  constructs domain events. Direct custom-event mapping is outside v1.
  Shipped in #872 as `engine__anim_marker`.
- [x] Agree pause/resume position preservation, stop resetting to frame 0,
  explicit idle-image overrides and visibility remaining independent.
- [x] Agree traversal-order markers, frame-zero start/restart semantics, occurrence
  identity, retained pending crossings and retry without silent loss/duplication.
  Shipped in #872 (`MarkerCursor`, 256-frame/64-handoff budget, clock stall).
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
- [ ] Specify the trigger JSONC schema, clip speed/transition fields, typed
  payload-to-target adapter APIs, binding/state layout and remaining
  mode-change semantics, including how a command batch replaces an unpumped
  initial cursor (`entering = true, pump_started = false`), how `stop` and
  `start: "dormant"` suppress initial frame-zero entry on zero-delta ticks, and
  what a queued command does to a target with genuinely crossed undrained
  markers. (Definition/marker schema, grammar limits and package wiring are
  done.)
- [ ] Make unknown `SpriteAnimation` keys and runtime-only fields fail closed at
  prefab load (today `deserializeStruct` ignores unknown keys and accepts
  `frame`, `timer`, `forward`, `finished_emitted`, `repetition`,
  `definition_dirty`, `definition_validated`, `marker_stalled`, `marker_cursor`,
  `marker_target_id`, `marker_playback_id` and inline `markers` from JSONC; the
  inline bind path does not reset the runtime fields). Required before `triggers`,
  `start` or `update` ship, so pre-rollout authoring cannot load silently or
  corrupt playback.
- [ ] Specify atomic save/queue handoff, persisted playback/cursor state, the
  persisted representation for `SpriteAnimation`'s non-serializable borrowed
  slices and their load-time rebind, and `PrefabRefresh` behavior once
  `SpriteAnimation` is no longer `.transient`;
  cross-entity tie ordering; marker subscriber indexes; `script_contract`
  target-liveness filtering and marked-clip lifecycle payload parity;
  pre-tick atlas validation ordering; and hot-reload identity/lifetime details.
  (Per-entity traversal backpressure is done.)
- [ ] Implement/test native and callback loop integration for the trigger
  command boundary, consumption ordering, unscaled input migration and
  compatibility shims; verify single advancement.
- [ ] Demonstrate a real consumer pilot, including persistence and failure paths.

Recommended implementation order: shorthand (done); marker contract (done);
triggers with a consumer pilot; persistence; pause migration; default driving.
Each has its own acceptance gate. The marker and trigger work shares the hooks
delivery/ordering contracts (`HOOK-DELIVERY-CONTRACT.md`, #857); the whole
hooks enhancement roadmap is not a prerequisite to the remaining stages.
