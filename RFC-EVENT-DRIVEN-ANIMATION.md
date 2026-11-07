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

The November 7 POC round (see "Owner-approved recommendations: POC evidence" before
the readiness list) prototyped every option the round-1 multi-model review
left open, against `main` `be0991e`. Its recommendations are evidence for the
owner, **not decisions**; nothing in that section is agreed until the owner
says so.

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
`marker_test.zig`. At the engine root, `zig build test-animation` runs the whole
`animation/test/animation_package_test.zig` file (compatibility tests plus its
marker-delivery, prefab-refresh and lifecycle tests) and excludes the legacy
files; `zig build test-animation-legacy`
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
such as `frames_pattern`, `from` or `to` is silently ignored. When `fps` is
present and numeric, the component then reaches `bindSpriteAnimation` with
empty `frames` and `definition` and fails with `InvalidAnimationFrames`, a
diagnostic that does not name the real mistake; when `fps` is missing or
non-numeric there is no bind and no diagnostic at all (see the malformed-value
paragraph below). The same walk populates every struct field, including runtime state
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
(`animation/src/sprite_animation.zig:213`). Runtime-only state must be rejected
or reset on bind before prefab authoring is considered closed.

Malformed values on known fields fail open as well, and in two different
ways. `deserializeStruct` treats a field whose value does not deserialize
exactly like an absent field: if the field has a default, the default is used
silently (`src/jsonc/deserializer.zig:273-277`), so `"mode": "lop"` plays as
`loop`, `"speed": "2"` plays at 1.0 and `"frames": "a.png"` becomes an empty
list (which then fails later as `InvalidAnimationFrames`). `fps` is the one
field without a default (`animation/src/sprite_animation.zig:80`), so a
missing or non-numeric `fps` makes the whole struct deserialize to `null`
(`deserializer.zig:278-285`), and the registry-component branch of
`applyComponent` has no failure path for that case: the component is simply
not attached and nothing is logged (`src/jsonc/component_apply.zig:201-222`;
the file header documents that scene loading "stays fire-and-forget"). A
prefab whose `SpriteAnimation` never appears therefore produces no
diagnostic at all. The fail-closed requirement below covers these malformed
and missing-required-field cases, not only unknown keys.

`markers` are also not a supported inline prefab field. Because
`bindSpriteAnimation` checks the pending cursor (`src/game/animation_runtime_mixin.zig:78`)
before `MarkerDefinitionRequired` (`:80`), a nonempty authored `markers` list in
a game that declares marker or lifecycle events fails with
`PendingAnimationMarkers` (the freshly defaulted `MarkerCursor` already has
`entering = true`, `animation/src/marker_cursor.zig:32,47-48`) whether or not
`definition` is set; without those events, `markers` without `definition`
returns `MarkerDefinitionRequired` and `markers` with `definition` is silently
overwritten from the clip. Inline `markers` must be rejected explicitly, not
interpreted.

Script component writes have a related gap: `labelle_component_set`
(`src/script_contract.zig:1517-1541`, `componentSetImpl`) routes engine
built-ins through `component_apply.zig`'s helpers, but dispatches registered
components (including `SpriteAnimation`) through
`std.json.parseFromSliceLeaky(..., .{ .ignore_unknown_fields = true, .allocate = .alloc_always })`
and `game.setComponent(ent, comp)` directly. Setting `SpriteAnimation` from a
script therefore bypasses `bindSpriteAnimation`, the `PendingAnimationMarkers`
check and `marker_target_id` preservation (`src/jsonc/component_apply.zig:202-217`),
leaves `definition`/`clip` unbound, and allocates any supplied
`definition`/`clip`/`markers` slices in `nested_entity_arena`
(`componentAlloc()`, `src/script_contract.zig:2546-2548`, reset on
`resetEcsBackend`) instead of borrowing session-owned `Library` strings.
The named tick's `engine__anim_marker` payload borrows those strings, and
`deliver()` checks only target liveness, not string lifetime. The November 7
POC reached this: a script sets inline `markers` plus `definition`/`clip`, the
tick queues a cue, `resetEcsBackend` runs, the arena is reused, and the script
tap emits garbage `definition`/`clip`/`marker` strings. The existing
pending-scene-event discard does not cover it (a mid-drain scene change keeps
the drain's local buffer). Routing the script path through
`bindSpriteAnimation` plus fail-closed validation makes it unreachable.

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
  invalid clip can execute multiple animation ticks while the manifest is not
  ready, plus the tick on the first ready update, before `speed` is zeroed
  (`src/game/animation_runtime_mixin.zig:153-168`). With no manifest or on a
  non-atlas renderer, automatic validation never stops it. The same routine
  sets `definition_validated = true` even when validation fails
  (`src/game/animation_runtime_mixin.zig:162-166`), so the automatic path never
  retries a stopped clip if a missing asset later becomes resident; recovery
  requires a rebind (which clears the flag) or a host-driven
  `validateSpriteAnimation` call plus an explicit `speed` restore. Setting
  speed to zero also does not retract already queued cues or suppress remaining
  handoffs for an entered frame (`src/named_animation_tick.zig:23-35`).
  **OPEN OBJECTION:** pre-tick validation alone does not define behavior before
  readiness or after validation fails. Specify whether unvalidated playback and
  its cues are allowed, how invalid-clip pending/queued cues are handled, and
  whether a failed clip is ever revalidated when the missing asset later
  becomes resident.
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
`anim.marker_cursor.pending()` is true, provided the game declares
`engine__anim_marker` or one of the lifecycle events; a game that declares
none of them never sees this error and the cursor is simply replaced
(`src/game/animation_runtime_mixin.zig:78`, `bindSpriteAnimation`). Two cursor
details constrain the trigger batch design:

1. `MarkerCursor` initializes with `entering: bool = true` and
   `pump_started: bool = false` (`animation/src/marker_cursor.zig`). Unlike
   `MarkerCursor.offer`, which checks `(self.entering and self.pump_started)`,
   `MarkerCursor.pending()` returns `true` whenever `self.entering` is set—even
   before the first tick has run and even when frame 0 has no markers. A
   freshly bound marked clip therefore fails `selectSpriteAnimation` with
   `PendingAnimationMarkers` (and prefab refresh logs a deferred-refresh
   warning, with no result code) until a tick pumps frame 0
   (`animation/test/animation_package_test.zig`). Applying a multi-command
   batch (`play(A) -> play(B)` or `restart -> stop`), or rebinding on the spawn
   frame before the first tick, requires allowing replacement of an unpumped
   initial cursor without emitting transient cues.
2. When a target has genuinely crossed markers that have not yet drained from
   `MarkerCursor`, `bindSpriteAnimation` refuses and leaves the old player
   intact, so the batch contract must choose whether a queued `play`/`restart`
   stalls/retries or drains-then-rebinds. That decision is still open.

Live prefab refresh currently refuses a blocked replacement rather than queuing
it: `src/jsonc/component_apply.zig:206-215` logs and returns, and
`src/jsonc/scene_loader/prefab_refresh.zig:403-408` continues to the ready callback without
a success result. The caller must retry the refresh after playback drains
(`animation/MARKERS.md`, "Delivery"). **OPEN OBJECTION:** specify retry ownership
and success notification for blocked refreshes; do not promise eventual
application merely from the current "deferred" diagnostic.

Removal is not deferred at all. A prefab refresh that drops `SpriteAnimation`
(`removeTransientType`, `prefab_refresh.zig`) and script `componentRemoveImpl`
(`src/script_contract.zig`) remove it unconditionally. The removed attachment
then fails `isAnimationMarkerTargetAlive`, so cues **already in the event
buffer** are dropped as well as undrained crossings: the November 7 POC
delivered 0 of 336 pending cues on removal. The retry-ownership decision must
cover removal as well as replacement.

### Event identity and typed payloads

Validate `on` against discovered event metadata. Dotted provider/event names
are the recommended author spelling; current assembler retention also accepts
qualified `provider__event` spelling in JSONC (assembler-side behavior from the
investigation, not re-verified in this pass). Specify alias and pack-namespace
resolution once and reuse it for validation, code generation and inspection.
Unknown names must produce actionable diagnostics. (The November 7 POC
evidence favors the qualified tag as canonical instead; see decision 17.)

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
was recommended; the November 7 POC evidence favors a sibling component
instead (decision 14). SpriteAnimation now carries `definition`/`clip` references, so
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
Start/restart emits frame-zero markers once; resume/restore does not replay them
("replay" here means re-emitting a cue already delivered; it does not by itself
decide when a not-yet-emitted frame-zero cue is first emitted, which is the
`frame-zero-conflicting-batches` decision).
Stop is a reset-to-stopped action, not a new playback start. Note that today a
zero-delta tick (`dt == 0`, `speed <= 0`, or `fps <= 0`) sets `budget.frames = 0`
in `src/named_animation_tick.zig` and still calls `MarkerCursor.pump`, which drains
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
  animation pass still receives `scaled_dt = dt * time_scale`, unless the
  independent `sprite_animations_paused` flag forces zero. It also does not stop
  root/plugin script ticks or event drains: the shipped generated loop gates
  only `runner.tick`/`PluginSystems.tick` on `scaled_dt > 0` and calls
  `script_contract.drainEvents`/`dispatchEvents` outside that gate without
  consulting `isPaused()` (`HOOK-DELIVERY-CONTRACT.md` §2). The pause migration
  must not assume the `paused` flag currently means "gameplay and scripts
  stopped".
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

A third loop variant is affected: under labelle-studio Play mode a paused
iteration fails `shouldTick()` and skips the whole SIM half, drains and
`g.tick` included (`HOOK-DELIVERY-CONTRACT.md` §2). Editor pause is separate
from `game.paused`, so under every pause option even unscaled clips freeze in
Play mode. Moving unscaled advancement outside the `shouldTick` gate to keep
the "unscaled keeps running" promise makes the event buffer grow without bound
there (351 undrained events after 401 iterations in the November 7 POC). The
migration must either exclude the preview loop explicitly or also move its
drains.

Acceptance: explicit pause and zero scale; scaled freezing/unscaled progress;
slow-motion restoration; notifications; independent animation suppression;
keyboard and menu unpause; native, callback and studio-preview generated loops. This is a
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

## Owner-approved recommendations: POC evidence

The round-1 multi-model review
([#794 comment](https://github.com/labelle-toolkit/labelle-engine/issues/794#issuecomment-6713132800))
left fourteen owner decisions open and found three more (15–17). On
November 7, six throwaway POCs prototyped the options against `main`
`be0991e`. Each POC kept the full `zig build test` suite green unless noted.
The POC branches are local (`poc/794-command-boundary`, `-trigger-shape`,
`-readiness-refresh`, `-validation-identity`, `-delivery-scale`,
`-clock-ownership`) and are evidence only; none is a proposed implementation.

**Owner approval recorded on November 7, 2026:** the owner explicitly approved
all 17 recommendations in the summary below ("The recommendation are approved
by me"), referring to the POC recommendations in PR head `2513e3f593015526cc832d247fdbf6f8bdc2f0f6`.
The summary entries are now accepted design directions, not unanswered owner
choices. Options are lettered as in the review comment; the POC evidence and
limitations below remain unchanged.

This approval does not approve implementation or certify the POC results as
independently reproduced. The subsequent review's three additional questions
remain open: stop/playback identity, remaining playback-action behavior, and
studio-preview pause scope. Review corrections also remain required, including
reconciling the accepted pause recommendation with independent local animation
pause and making the decision register complete. Do not silently infer answers
to those questions or drop an agreed requirement when incorporating the approved
recommendations. The pipeline-generated proposal's inaccurate claim to be the
committed PR document must also be corrected; it is not an owner decision.

### Summary

| # | Decision | Approved recommendation | Deciding evidence |
| --- | --- | --- | --- |
| 1 | `prefab-validation-boundary` | (c) assembler diagnostics + engine fail-closed backstop | Assembler-only misses runtime JSONC, studio hot-push, `labelle_component_set` and Zig-built components |
| 2 | `identity-fields-authoring` | (b) reset at authored-data entry points, plus (1) rejecting authored values | Forged `marker_target_id` lets a stale cue reach a hook today |
| 3 | `unpumped-initial-cursor` | (a) unpumped cursor is replaceable | (b) emits transient cues **and deadlocks** stopped/dormant cursors |
| 4 | `queued-command-vs-pending-cursor` | (b) drain within budget, else stall (a) | Neither loses cues; plain stall plays the replaced clip one extra update |
| 5 | `frame-zero-conflicting-batches` | (a) | (b) needs a persisted "deferred frame zero" state; (c) emits a transient cue |
| 6 | `pre-readiness-playback-policy` | (b) hold, plus an explicit host "assets ready" call | Today an invalid clip's queued cue is delivered and the clip never recovers |
| 7 | `blocked-refresh-retry-owner` | (a) engine parks and applies, **including removal** | Removal today delivers 0 of 336 pending cues |
| 8 | `script-drain-liveness` | (a) filter in `drainEvents` | (b) breaks 4 shipped hook-delivery tests |
| 9 | `legacy-cue-identity-scope` | Internal enqueue-time attachment guard for numeric and lifecycle cues | (c) misdelivers to a reused ID; marked-clip `engine__anim_complete` reaches a replacement today |
| 10 | `cross-entity-marker-order` | (a) traversal order, documented | Sort adds ~25 ns/cue and is deterministic but not chronological |
| 11 | `marker-subscriber-indexes-v1` | (b) defer | 1,000 cues × 50 subscribers ≈ 96 µs/frame (~0.6% at 60 fps) |
| 12 | `persistence-owner-stage` | (c) transient SpriteAnimation + saveable sibling, **landing with triggers** | Load and refresh silently revert a triggered prop today |
| 13 | `local-animation-pause-input` | (b) `paused` gates scaled clips; subsystem flag removed | Only (b) matches the agreed clock model; the flag has no non-test users |
| 14 | `trigger-component-boundary` | (b) sibling `AnimationTriggers` component | Only (b) reaches AnimationDef consumers; fields on SpriteAnimation are lost by any fresh construction |
| 15 | `manual-driver-opt-out-mechanism` | (a) per-instance `drive: engine \| manual` | Default-on broke 1 of ~1,520 tests; a double-advance detector names unmigrated projects |
| 16 | `dormant-scene-entry-reconciliation` | (a) same-entity predicate evaluated lazily on first engine pass; (d) as v1 fallback | `onReady` fires before save restore and before siblings |
| 17 | `trigger-event-name-canonicalization` | (b) the GameEvents tag (`provider__event`) is canonical, dotted is an alias | The runtime identity is the tag; dotted → tag is lossy in reverse |

**Coupled decisions.** 3, 4 and 5 constrain each other: choosing 3(b) also
changes 5's table (restart → stop then emits one cue under 5(a) and 5(b)
alike) and makes 4's drain pump held cursors. 1, 2 and 8 share one change:
routing `labelle_component_set` through validation and `bindSpriteAnimation`.
7 and the removal finding in section 3 are one decision. 12 and 14 compose:
trigger bindings ride the transient sibling, continuity the saveable one.

### Cursor and command boundary (3, 4, 5)

POC: a minimal per-target command queue applied at the tick boundary
(~55 engine lines, 10 tests).

- **3.** Under (a) a spawn-frame `play(run)` over a fresh `walk` cursor emits
  0 `walk.start` and 1 `run.start`; it needs one predicate
  (`MarkerCursor.pendingPumped()`). Under (b) astra's claim holds: a
  zero-frame pump still emits the frame-zero marker, because entry
  (`marker_cursor.zig:78`) runs before the budget check (`:116`). Worse, the
  agreed rule that stopped/dormant cursors do not enter frame zero means they
  are never pumped, so under (b) they stay pending forever: a `restart` after
  `stop` was still queued after 100 boundaries, and 20 `[restart, stop]`
  batches left 38 of 40 commands stuck. A "non-emitting pump" is (a) renamed.
- **4.** A 1,000-beat backlog then `play(run)`, with a producer re-queuing
  every update:

  | Policy | Applied at update | Old-clip cues | Max queue |
  | --- | --- | --- | --- |
  | (a) stall | 17 | 678 | 17 |
  | (b) drain | 16 | 668 (exactly the backlog) | 16 |

  Neither livelocks, since a pending cursor refuses new time. When the
  backlog exceeds the remaining budget, drain falls back to stall, so (b) is
  (a) plus a boundary drain. Drain must share the per-update budget (a new
  spent-handoffs counter) and must never pump a held cursor. Either way the
  per-target queue needs a bound or coalescing.
- **5.** `walk.start` cues at the boundary + later; owner is the restart's
  playback identity wherever one is emitted:

  | Batch | (a) | (b) | (c) |
  | --- | --- | --- | --- |
  | restart → pause | 1 + 0 | 0 + 0 | 1 + 0 |
  | restart → stop | 0 + 0 | 0 + 0 | 1 + 0 |
  | restart → pause → resume | 1 + 0 | 0 + 1 (on resume) | 1 + 0 |

  (b) needs a "frame zero deferred" state that changes today's pause
  behavior (the tick drains `entering` at speed 0) and that save/restore must
  persist. (c) must pump the restart's entry before `stop` resets it, which
  is the transient cue section 3 forbids.

Open detail the POC assumed: whether `stop` keeps or replaces the playback
identity.

### Validation, identity and the script path (1, 2, 8)

POC: a SpriteAnimation-specific strict hook (~60 lines; +12 in
`component_apply.zig`, +25 in the script path), 13 tests.

- **1.** A generic deserializer flag is not enough: which fields are
  runtime-only is a property of SpriteAnimation, so it needs a per-component
  allow-list. Of nine malformed SpriteAnimations, five attach today
  (unknown key ignored; authored `marker_target_id` and `frame` kept; bad
  `mode`/`speed` defaulted) and four are dropped silently or with a
  misleading error (missing or string `fps`; `clip: 7`; inline `markers` →
  `PendingAnimationMarkers`). Strict mode rejects and logs all nine, still
  attaches a well-formed one, breaks no fixture, and covers hot reload
  (`reloadPrefabSource`): a rejected reload leaves the live component intact.
  Assembler-only validation cannot see runtime-loaded scenes, studio
  hot-push, script JSON or Zig-built structs, which is astra's blocking
  finding made concrete. The batch/packed script setters are not a bypass:
  they already refuse SpriteAnimation.
- **2.** Confirmed: after `resetEcsBackend` (which does not clear
  `event_buffer`), a scene authoring `"marker_target_id": 1` lets the stale
  cue pass liveness and reach a hook. (b) closes it, but the reset cannot sit
  inside `bindSpriteAnimation`, because `selectSpriteAnimation` also binds
  and must keep its target. It belongs at the prefab and script entry
  points, before prefab refresh copies the old target back. Zig gameplay code
  can still forge an id under (b). (c), an engine side table (Emitter
  pattern, #750), touches about six lifecycle points and desyncs if anything
  writes the ECS backend directly; it is worth it only if code-level forging
  matters.
- **8.** Today the script tap forwards stale markers (2 in the test). (a) is
  4 lines and drops them while live markers flow. (b) fails four existing
  tests (effective-next-drain subscription, scene lifecycle #864/#868) and
  would make `emitSync` events reach scripts for the first time, so it is not
  an equal alternative. Script `labelle_component_set` on SpriteAnimation
  should return a retry code (the POC used `-2`) while the cursor is pending,
  mirroring prefab refresh.

### Readiness and blocked refresh (6, 7)

POC: a policy switch plus a "validation passed" field (~40 lines for 6,
~80 for 7). Test clip: 3 frames at 4 fps, `start` on frame 0, `footstep` on
frame 1, 90 frames at 60 Hz, atlas available from frame 30.

| Scenario | Policy | Cues before ready | Total | Cues from invalid clip |
| --- | --- | --- | --- | --- |
| Atlas late | today | 2 | 5 | 0 |
| Atlas late | (b) hold | 0 | 3 | 0 |
| Missing frame, fixed at 30 | today | 1 | 1 | **1** |
| Missing frame, fixed at 30 | (b) hold | 0 | 0 | 0 |
| Missing frame, fixed at 30 | (c) hold + revalidate | 0 | 3 | 0 |

- **6.** Today the invalid clip's `start` cue is queued in the same frame
  validation fails and still reaches the receiver, and the clip stays stopped
  after the atlas is fixed. Hold is one gate in `sprite_animation_tick.zig`
  and no longer zeroes `speed`, so a later success resumes at authored speed.
  Hold freezes clips in scenes without an asset manifest (validation never
  runs there), so (b) requires an explicit host "assets ready" call. Hold also
  skips the frame-zero sprite sync until validation. (c) can hook
  `TextureManager.version` (`src/atlas.zig:226`) and worked in the test, but
  each failed retry logs an error, `invalidateAtlasBinding` does not bump the
  version, and an unloaded atlas does not re-hold a passed clip; it is a
  follow-up.
- **7.** A 336-crossing backlog, then a prefab push:

  | Push | Policy | Applied | Cues delivered |
  | --- | --- | --- | --- |
  | Replace | today | never | 285 |
  | Replace | (a) engine parks | frame 6 | 304 + completion event |
  | Replace | (b) result code | never | 285 |
  | Remove | today | immediately | **0** |
  | Remove | (a) engine parks | frame 6 | 268 + completion event |

  (a) stays inside the engine: a parked list (latest push per entity wins),
  applied at the **start** of the sprite tick (after the previous frame's
  dispatch; applying at the end lost ~30 just-queued cues), cleared on world
  reset, with an `engine__anim_refresh_applied` event. It needs no studio
  change. (b) needs a new `editor_reload_prefab` return code and a polling
  host. The alternative for removal, documenting it as cancellation like
  entity destroy, is simpler but loses every pending cue. The script removal
  path (`componentRemoveImpl`) needs the same treatment; the POC did not
  cover it. On-ready still fires immediately on a blocked push.

### Delivery identity, order and scale (9, 10, 11)

POC: a test ECS backend that reuses freed IDs (the in-repo mock never does),
ReleaseFast benchmarks on `MockEcsBackend`.

- **9.** Two legacy `event_frames` cues on one tick; the first hook destroys
  the second entity and spawns a replacement with the same ID:

  | Mode | Cues delivered (2 = misdelivered) |
  | --- | --- |
  | today | 2 |
  | (c) liveness filter on bare entity | **2** |
  | internal attachment guard | 1 |

  (c) only helps when the replacement has no SpriteAnimation. Separately, on
  a `.once` marked clip whose ID is reused, the marker cue is dropped but
  `engine__anim_complete` reaches the replacement, because the delivery
  filter checks only `engine__anim_marker`. The guard records
  (buffer index, `target_id`) at enqueue in a side list swapped with the
  batch and checks it at delivery; public payloads are unchanged. Clips
  without markers get a lazily assigned `target_id`. Cost at 1,000 cues per
  frame: ~0.5 µs tick + 12.7 µs drain (~13 ns/cue), matching (c)'s 12.0 µs.
- **10.** The only in-repo ECS iterates in hashmap order: stable across
  identical runs, not creation order, reshuffled by churn; real backends live
  in other repos. A `(target_id, sequence)` sort holds after churn but places
  later-created entities after older ones (deterministic, not
  chronological). Sorting queued cues costs +24% tick at 100 entities and
  +42% at 1,000 (~25 ns/cue); sorting entities is worse (+55% at 1,000) from
  lost locality. A sort would also have to reorder the guard list from 9.
- **11.** Drain per frame, one cue per entity, subscribers filtering on 8
  names:

  | Entities | Subscribers | All receive | Pointer-keyed index |
  | --- | --- | --- | --- |
  | 100 | 1 / 10 / 50 | 1.75 / 3.4 / 10.2 µs | 1.93 / 2.0 / 2.2 µs |
  | 1,000 | 1 / 10 / 50 | 15.3 / 30.1 / 96.4 µs | 17.1 / 18.2 / 19.7 µs |

  Fan-out is ~1.7 ns per cue per subscriber; an index costs ~2 ns/cue with
  one subscriber and wins from about 10. Keep the benchmark as the gate; if
  indexes come, key on the Library's shared name pointer, not the string.

### Clocks, driver ownership, dormant entry (13, 15, 16)

POC: ~140 engine lines, 6 tests.

- **13.** Does a clip advance and emit cues (scaled / unscaled)?

  | Input | Today | (b) | (d) |
  | --- | --- | --- | --- |
  | `setPaused` | **Y / Y** | n / Y | Y / Y |
  | `time_scale = 0` | n / n | n / Y | n / Y |
  | `sprite_animations_paused` | n / n | removed | removed |
  | per-animation `paused` | n/a | n/a | n / n |

  Today `setPaused` freezes no sprites, and (d) keeps that. `speed = 0`
  already pauses one animation; (d) adds a pause that keeps the speed value
  and can layer on (b) later. `sprite_animations_paused` is referenced only by
  engine tests. The studio-preview caveat is in section 5.
- **15.** Default-on driving with `drive: manual` excluded: a project still
  shipping a `sprite_animation_tick` script advances at 2× and a per-frame
  advance-epoch detector warns; `drive: manual` next to an engine-driven
  instance advances each once with no warning; `setDriveSpriteAnimations(true)`
  becomes a no-op and `(false)` stays the global opt-out. Flipping the
  default broke exactly one test (the "does not advance unless enabled"
  test, now opted out explicitly), and the detector found no hidden double
  drivers.
- **16.** Sketch: `start: dormant`, `start_when: "Comp.field"` (a bool on
  the same entity) or `"state:<name>"`, a once-only latch, evaluated on the
  first engine pass after the entity appears. `onReady`/`postLoad` are wrong:
  they fire per entity before later siblings (`HOOK-DELIVERY-CONTRACT.md`
  §11), and `loadGameState` respawns prefabs (firing `onReady`) before it
  restores saved component data. The lazy pass sees restored state and
  re-arms on prefab refresh, whereas a sync event under (b)/(d) has already
  been consumed by then. ~35 lines, following the
  `validateSceneSpriteAnimations` latch precedent. Cross-entity predicates
  have no ordering guarantee, so v1 is limited to the same entity plus game
  state.

### Trigger shape, naming and persistence (12, 14, 17)

POC: 10 tests; the assembler was read at `5718043`.

- **14.** The same trigger list loads via `addEmbeddedPrefab`/`spawnPrefab`
  in both placements, and one `factory__machine_on` switches dormant `idle`
  to `run`. (a): 4 lines on SpriteAnimation, a 17-line shared type and a
  13-line router; (b): no SpriteAnimation change, a 19-line component and a
  27-line router, and it can live in game code. Only (b) drove an
  AnimationDef consumer (`DoorState`, via the `anim_def_name` walk). Under
  (a), `selectSpriteAnimation` keeps triggers only because it copies the old
  struct; any code building a fresh SpriteAnimation drops them. Malformed
  trigger values fail silently in both (`"play": "lop"` loads as an empty
  entry), and (b) can validate in its `postLoad`, which runs on spawn and
  refresh. Both share one surprise: `refreshEntity` re-applies every transient
  key (`prefab_refresh.zig:351-358`), so editing only the triggers resets
  playback to dormant `idle`. Only (b) leaves room to refresh components one
  at a time later.
- **17.** The runtime identity is the tag (`@hasField(GameEvents, …)`,
  `game.zig:1819`). Dotted names carry the plugin import name
  (`labelle-physics.hit`) while tags carry the sanitized one
  (`labelle_physics__hit`, assembler `plugin_events.zig:19-33`), so tag →
  dotted is ambiguous and inspection should show the tag. Tags are already
  checked for duplicates (`scripting_declare.zig:1069`, `:1103`, `:1152`),
  and a dotted name cannot collide with a tag. Root events have no dotted
  form except the manifest's invented `game.<event>` realm. Pack events become
  `<pack>__<event>`, but the pack rewriter does not rewrite string values
  (`pack_refs.zig:210-214`), so pack prefabs must use the full name or the
  resolver needs pack-local scoping. The resolution logic is split across
  `event_consumption.zig:227-265` (both spellings) and generated
  `FlowNodes.resolve` (`plugin_registries.zig:288-296`, dotted only); lift
  one resolver for validation, codegen and inspection. The consumption
  filter already retains either spelling. Naming trap: the flow catalog's
  `"qualified"` field holds the dotted form (`flow_catalog/json_writer.zig:161`).
  This reverses section 3's "dotted is the recommended spelling".
- **12.** A saveable `AnimationPlayback` sibling round-trips clip, frame,
  elapsed and playing state across save/reset/load (restored in `postLoad`,
  `load.zig:769`), the next tick continues, and triggers keep working. Lost:
  the cursor's pending crossings, sequence counter and frame-zero entry
  state, and the playback id (rebind mints a new one); restoring the cursor
  needs a MarkerCursor API. The save serializer cannot write strings
  (labelle-core `serde.zig:64`), so the clip is stored as a name hash and a
  renamed clip fails restore. There is no pre-save hook, so live state must
  be copied into the sibling by some new mechanism. Prefab refresh skips
  saveable components (`prefab_refresh.zig:484-487`), so the sibling survives
  refresh, but nothing signals refresh completion to trigger the restore.
  Because triggers create state nobody authored, and both load and refresh
  silently revert a triggered prop to dormant today, persistence should land
  with triggers rather than after them.

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
  Traversal and queue handoff shipped in #872 (`MarkerCursor`,
  256-frame/64-handoff budget, clock stall); command-boundary frame-zero semantics
  and restore suppression remain outstanding as specified in section 4.
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
  inline bind path does not reset the runtime fields). The same item must cover
  malformed values on known fields (today they silently fall back to the field
  default), a missing or non-numeric `fps` (today the component is silently
  not attached, with no log), and `labelle_component_set` parity for
  `SpriteAnimation` (`src/script_contract.zig:1517-1541` currently bypasses
  `bindSpriteAnimation`, pending-cursor checks and `marker_target_id`
  preservation). Required before `triggers`, `start` or `update`
  ship, so pre-rollout authoring cannot load silently or corrupt playback.
- [ ] Specify atomic save/queue handoff, persisted playback/cursor state, the
  persisted representation for `SpriteAnimation`'s non-serializable borrowed
  slices and their load-time rebind, and `PrefabRefresh` behavior once
  `SpriteAnimation` is no longer `.transient`;
  cross-entity tie ordering; marker subscriber indexes; `script_contract`
  target-liveness filtering and marked-clip lifecycle payload parity;
  pre-tick atlas validation ordering, pre-readiness playback, invalid-clip cue
  policy and failed-clip revalidation after a late asset; blocked prefab-refresh
  retry ownership and success notification; and hot-reload identity/lifetime
  details.
  (Per-entity traversal backpressure is done.)
- [ ] Implement/test native and callback loop integration for the trigger
  command boundary and consumption ordering. Depends on
  `unpumped-initial-cursor`, `queued-command-vs-pending-cursor` and
  `frame-zero-conflicting-batches`.
- [ ] Implement/test the unscaled input migration and compatibility shims in
  native, callback and studio-preview loops; verify single advancement.
  Depends on `local-animation-pause-input` and
  `manual-driver-opt-out-mechanism`.
- [ ] Demonstrate a real consumer pilot, including persistence and failure paths.

Recommended implementation order: shorthand (done); marker traversal and queue
handoff (shipped; delivery-identity and ordering decisions outstanding);
triggers with a consumer pilot and playback persistence (see
`persistence-owner-stage`); pause migration; default driving.
Each has its own acceptance gate. The marker and trigger work shares the hooks
delivery/ordering contracts (`HOOK-DELIVERY-CONTRACT.md`, #857); the whole
hooks enhancement roadmap is not a prerequisite to the remaining stages.
