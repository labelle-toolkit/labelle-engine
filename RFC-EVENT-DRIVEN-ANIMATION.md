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

The November 7 POC round (see "Owner-approved recommendations: POC evidence"
before the readiness list) prototyped the options the round-1 multi-model
review left open, against `main` `be0991e`. On November 7 the owner approved
all 17 POC recommendations and three further playback and preview decisions.
These 20 items are **decided**, and this document treats them as design
requirements. The approval covers design direction only. It does not approve
implementation, merging or deployment, and it does not certify the POC
measurements. Those stay reported evidence except where the November 8
revalidation re-ran them.

**Evidence labels** used from here on:

- *Demonstrated*: read in shipped code at `be0991e`, or produced by a test or
  probe whose commit, command and output are recorded in
  [`docs/investigations/rfc-793/poc-794/`](docs/investigations/rfc-793/poc-794/README.md).
- *Reported*: a November 7 POC result whose code is not available to re-run
  (see "Owner-approved recommendations: POC evidence").
- *Proposed*: approved behavior that is not implemented on main.

**Provenance.** The RFC is this file as committed on branch
`rfc-event-driven-animation`; cite it by commit. Review-pipeline jobs may
review an author rewrite generated inside the job instead of the committed
file. Such a rewrite is not this RFC, and its text, line numbers and claims are
not attributable to any commit. Reviewed commits, artifact hashes and the
committed-versus-reviewed differences are recorded outside this document, in
[`docs/investigations/rfc-793/review-provenance.md`](docs/investigations/rfc-793/review-provenance.md).
Commits `55acd26` and `bf4abea` recorded the owner approvals. Later commits
apply review corrections only. No reviewer has approved a corrected revision;
each one needs a fresh four-reviewer review.

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
Approved decision 15 (proposed) represents manual ownership per instance as a
`drive: engine | manual` field on `SpriteAnimation`;
`setDriveSpriteAnimations(false)` stays the global opt-out. Until fail-closed
validation (decision 1) ships, a `drive` key is silently ignored today like any
unknown key, so the instance stays engine-driven. `drive` is therefore in the
fail-closed list (readiness).
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

Not yet specified in this boundary (implementation work, not owner decisions):
definition reload and reconciliation. Trigger-command mechanics follow approved
decisions 3–5 (section 3). `Library.load` rejects a duplicate name and there is no
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
component is a required acceptance item under approved decision 1 (see
section 3 and the readiness list).

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
  **Approved decision 6 (proposed):** a definition-bound clip holds, with no
  advance and no cues, until validation passes. Scenes without a manifest get
  an explicit host "assets ready" call. Automatic revalidation after a late
  asset (option (c)) is not part of the decision; it stays a follow-up, and the
  atlas-version hook it would use has the limits described under decision 6 in
  the POC section.
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

The proposed surface remains declarative. Under approved decision 14 the
trigger bindings live on a sibling `AnimationTriggers` component, and
`SpriteAnimation` gains no trigger fields. Under decision 17 the event names
use the canonical GameEvents tag. `start` and its reconciliation predicate
(decision 16) also live on `AnimationTriggers`. Dormancy exists only to wait
for a trigger, and `SpriteAnimation` gains no trigger-driven fields. The
example is illustrative: the event names are hypothetical domain events, not
existing Flying Platform events, and the exact field names and syntax belong to
the schema specification (readiness list):

```jsonc
"SpriteAnimation": {
  "definition": "animations/factory_machine.jsonc", "clip": "run",
  "fps": 8
},
"AnimationTriggers": {
  "start": "dormant",
  "triggers": [
    { "on": "factory__machine_on", "play": "loop", "start_when": "Machine.powered" },
    { "on": "factory__machine_off", "action": "stop" }
  ]
}
```

None of this trigger surface is implemented on main as of `be0991e`. The
`animation/` package has no trigger schema, and `Definition.parse` rejects a
`triggers` field inside a definition file. A prefab authored against this
proposal today still loads without error and never reacts:

- `AnimationTriggers` is not a registered component, so it only produces a
  warn-once (`src/jsonc/component_apply.zig:225-239`).
- `start` or `triggers` placed on `SpriteAnimation` by mistake are silently
  ignored by the struct deserializer (section 2, "Expansion contract").

Under approved decision 1, trigger rollout ships both assembler diagnostics and
the engine's fail-closed backstop, so pre-rollout authoring fails closed.
Acceptance must include both cases.

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
   initial cursor without emitting transient cues. Approved decision 3
   (proposed) does exactly that: `pending()` distinguishes a pumped cursor from
   an unpumped one.
2. When a target has genuinely crossed markers that have not yet drained from
   `MarkerCursor`, `bindSpriteAnimation` refuses and leaves the old player
   intact. Approved decision 4 (proposed): the boundary drains the backlog
   within the shared per-update budget and then rebinds in the same boundary.
   When the budget runs out, the command stalls and retries at the next
   boundary in per-target order. Approved decision 3 makes an unpumped initial
   cursor (point 1) replaceable without transient cues. The same drain applies
   when the queued command is `stop` (see "Stop, retained crossings and
   delivery validity" below).

Live prefab refresh today refuses a blocked replacement instead of queuing it
(demonstrated). `src/jsonc/component_apply.zig:206-215` logs and returns, and
`src/jsonc/scene_loader/prefab_refresh.zig:403-408` continues to the ready
callback without a success result. Today the caller must retry once playback
drains (`animation/MARKERS.md`, "Delivery").

**Approved decision 7 (proposed):** the engine parks the push, keeping the
latest push per entity. It applies the push at the start of the sprite tick
once the cursor has drained, and emits a completion event. The same rule covers
prefab-refresh removal and script `componentRemoveImpl`. The POC did not
prototype the script removal path, so covering it is a requirement, not
demonstrated behavior.

Two consequences of decision 7 (proposed):

- **Script `labelle_component_set` of `SpriteAnimation`** is a push like a
  prefab refresh. Decisions 1, 2 and 8 route it through validation and binding.
  While the cursor is pending it is parked under the same rule (latest push per
  entity wins) and reports acceptance; the completion event reports
  application. The retry code mentioned under decision 8 in the POC section was
  a POC note, not part of any approval.
- **Ordering at the boundary, per target:** (1) drain the pending cursor within
  the shared budget (decision 4); (2) once drained, apply the parked push;
  (3) apply that target's trigger commands in dispatch order to the resulting
  attachment, validating lifetime at application. Parked pushes coalesce, and
  commands never do; they are separate queues, and the push always goes first.
  A replacement keeps the attachment's `marker_target_id`
  (`component_apply.zig:211`), so commands still apply to it. A removal ends
  the attachment, so its commands are skipped.

Removal is not deferred at all today. A prefab refresh that drops
`SpriteAnimation` (`removeTransientType`, `prefab_refresh.zig:477-482`) and
script `componentRemoveImpl` (`src/script_contract.zig:1790-1797`) both remove
it unconditionally. The November 8 probe measured this shipped behavior
(demonstrated, `docs/investigations/rfc-793/poc-794/`). The fixture builds a
400-frame backlog of 267 marker cues and 133 loop events, of which 64 are
already handed off. After removal:

- **None of the 267 backlog marker cues is delivered.** The 43 queued ones
  (derived: 64 queued minus 21 loop events) fail
  `isAnimationMarkerTargetAlive`, and the occurrences retained in the cursor
  are destroyed together with the component.
- **The 21 already-queued `engine__anim_loop` events of the removed attachment
  still reach hooks,** because the delivery filter covers only
  `engine__anim_marker` (see decision 9).

### Event identity and typed payloads

Validate `on` against discovered event metadata. Under approved decision 17,
the qualified `provider__event` spelling (the GameEvents tag) is canonical and
dotted `provider.event` is accepted as an alias. Inspection and diagnostics
show the tag. Current assembler retention accepts both spellings in JSONC
(assembler-side behavior from the investigation, not re-verified in this
pass). Specify alias and pack-namespace resolution once and reuse it for
validation, code generation and inspection. Unknown names must produce
actionable diagnostics.

The existing consumption filter scans JSON/JSONC for both spellings
(assembler-side, not re-verified here). Reuse it;
test events referenced only by root/pack prefabs, staged dependency prefabs,
and any runtime-loaded authoring path. A newly introduced generic marker
channel must be retained when only a marker label appears in authored data.

### Targeting and lifetime

**Agreed policy:** exact-entity targeting by default, explicit groups, and
opt-in broadcast. There is no implicit ancestor walk. These are semantic target
forms; concrete authored syntax is specification work, not an owner decision. Each trigger explicitly
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

Approved decision 14: trigger bindings live on a sibling `AnimationTriggers`
binding component with an explicit adapter boundary that can also target
AnimationDef consumers. SpriteAnimation itself gains no trigger fields. This
replaces the September recommendation of fields on SpriteAnimation.
SpriteAnimation now carries `definition`/`clip` references, so
a def/clip binding exists for that component; AnimationDef reuse still needs
its own explicit binding, because transition tables alone do not identify which
game component to control.

### Playback state and repeated requests

Define playing, paused, stopped/dormant and completed states, with this action
table completed as part of the implementation specification:

| Request | Contract to specify |
| --- | --- |
| `play: once/loop/ping_pong` | Playing the same active clip with unchanged playback mode is a no-op, for every mode. Playing a different clip starts at frame zero with a new playback identity. Playing a completed/stopped clip starts it again with a new identity. Owner-approved: `play` on paused playback of the same clip resumes from the preserved position. An explicit playback-mode change preserves the current position and applies going forward. |
| `play` composition (derived from the rows above) | **Same playback, same id.** A same-clip `play` that resumes paused playback, or that only changes the mode of a playing or paused playback, continues that playback. It keeps `marker_playback_id`, re-emits nothing, and (if paused) resumes with the new mode. Because today every bind mints an id (`animation_runtime_mixin.zig:95`), this path must not rebind. **Terminal states start over.** On completed or stopped playback, `play` in any mode starts again at frame zero with a new identity. The completed/stopped rule governs, and the mode-change rule applies only to playing or paused playback, since a terminal playback has no "going forward". **New playbacks are playing.** `restart`, or `play` of a different clip, on paused playback starts a new playback that is playing. The paused state belonged to the old playback; restart → pause in one batch is what yields a paused restart (decision 5(a)). |
| `stop` | Agreed: reset playback to frame 0 and remain stopped. Reset the residual timer, direction, repetition and marker cursor; invalidate the stopped playback identity so its queued cues cannot affect a later playback. Repeated stop is a no-op. An explicitly authored idle image may override the displayed image. Visibility is unchanged. Mechanism (proposed): crossings the cursor still retains are drained first, as for any queued command (decision 4). The reset then applies. Stop retires the current `marker_playback_id` by minting a fresh id immediately; the stopped playback holds that id and emits nothing under it. The next start mints another. The field is therefore never 0 after a stop, so the named tick's "mint when 0" path (`src/named_animation_tick.zig:14`) cannot re-mint it silently. See "Stop, retained crossings and delivery validity". |
| `pause` / `resume` | Agreed: pause preserves frame and residual timer; resume continues paused playback from that position. Repeated pause is a no-op. Owner-approved: `resume` on stopped or completed playback is a no-op; an explicit `play` starts it again with a new identity. This per-animation paused state is the independent local animation pause of section 5. A paused playback receives no elapsed time, so it enters no new frames. Pausing does not cancel the handoff of a frame already entered at the command boundary: under decision 5(a), restart → pause emits frame zero once (see "Frame zero under pause"). Local resume remains subject to the applicable game clock and editor-pause gates. |
| `restart` | Reset frame, timer, direction, repetition and marker cursor; create a new playback identity; update the visible sprite even without a later frame crossing. |
| `start: dormant` | Shows frame 0 of the bound clip and does not advance or enter frames until a request starts it. Reconciliation on scene or prefab entry and after loading follows approved decision 16 (see "Dormant entry reconciliation"). |

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
(`animation/test/animation_package_test.zig:206-233`: entity `b` has
`speed = 0`, the receiver still counts its cue, and `b` stays on frame 0). Implementing `start: "dormant"`
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
rule follows the crossing contract below. Speed zero, mode changes and
completion follow the action table above and approved decisions 3–5.

Use explicit `restart` to synchronize recipients. Broadcast `play` alone does
not synchronize existing loops because the identical-loop request is a no-op.
A restart batch resets its recipients together at the animation boundary.

#### Stop, retained crossings and delivery validity

When a `stop` reaches the command boundary, three groups of occurrences can
exist. Existing approvals govern each group, so no new decision is needed.

| Group | Where it lives | Governing approval | Result |
| --- | --- | --- | --- |
| Retained crossings: frames the cursor has entered but not handed off (`steps`, `loop_pending`, `complete_pending`, or an entry interrupted by the event budget). These are the "genuinely crossed" occurrences of decision 4. | `MarkerCursor` | The agreed no-drop rule (section 4: "Do not silently drop, aggregate or overwrite pending cues"), the agreed interruption rule ("Interruption does not erase already-crossed markers") and approved decision 4's boundary drain | Drained within the shared per-update budget, under the stopped playback identity, before the reset. If the budget runs out, the stop stalls to the next boundary in per-target order, exactly as a queued `play`/`restart` does under decision 4. The action table's cursor reset then applies to an empty cursor. |
| An unpumped initial entry (`entering = true`, `pump_started = false`) | `MarkerCursor` | Approved decision 3 (it is not a crossing and is replaceable without cues) and decision 5(a) (restart → stop emits nothing) | The reset discards it, and nothing is emitted. |
| Occurrences already handed off to `game.event_buffer` | the event queue | Approved `stop-playback-identity`, the agreed interruption rule, and the agreed delivery contract in section 4 ("Hooks … must validate the entity and action at delivery. Playback identity allows rejection of an old attack's cue after interruption.") | Delivered with the stopped `playback_id`. Stop retires that id, and no later playback ever receives it, so the cue can always be told apart from a later playback's cues. |

Validity at delivery has two parts:

- *Attachment validity* is engine-enforced. A cue whose attachment is gone is
  dropped: today for `engine__anim_marker` on the native/flow path, extended to
  scripts by decision 8 and to numeric and lifecycle cues by decision 9.
- *Playback validity* belongs to the hook. A hook that must act only for the
  current playback compares the cue's `playback_id`, and stop's invalidation
  makes that comparison sufficient. No engine filtering by `playback_id` is
  required.

The previous revision (`a5dd7f8`) recommended that stop cancel retained
crossings without draining and that the engine drop the stopped playback's
queued cues. That recommendation is **withdrawn**. It would have revised the
agreed no-drop and interruption rules for stop, and no approval did that.

#### Frame zero under pause

*Advancement* is offering elapsed time to the cursor: new beats, frame changes,
loop and completion crossings. *Boundary entry* is handing off the markers of
the frame a playback occupies because a start or restart was applied at the
command boundary. A pause blocks advancement. It never cancels the handoff of
a frame already entered. The pause can be local, a game pause of a scaled clip,
or `time_scale == 0`. Shipped code already separates the two: a zero-delta
tick sets `budget.frames = 0` but still pumps the cursor, which drains
`entering` before it checks the frame budget (`src/named_animation_tick.zig:23-29`:
"A cue for a frame already entered may still finish its queue handoff while
paused";
`animation/src/marker_cursor.zig:78-92`, `:116`). Implementing decision 5(a)
therefore means:

| Batch or state | Boundary result | Afterwards |
| --- | --- | --- |
| restart → pause | frame-zero cues handed off once, under the restart's new identity | no advancement; resume continues and does not replay them |
| `play` of a new clip → pause | the same: the playback starts after applying the batch (frame-zero row, section 4) | as above |
| restart → stop | nothing (the unpumped entry is discarded) | stopped, entry suppressed |
| pause of a running playback | nothing new | frozen at its frame and residual time |
| stopped or dormant | entry suppressed until playback starts | — |
| held before validation (decision 6) | entry deferred: no advance and no cues, and no frame-zero sprite sync | emitted once when validation passes |
| editor-paused (studio Play mode) | entry deferred: no simulation half runs | emitted once on the next ticking update |

**Budget exhaustion.** The boundary entry shares the per-update handoff budget
with decision 4's drain (64 handoffs per entity per update). If frame zero has
more cues than the budget allows, the cursor stops mid-entry: `entering` stays
true, `marker_index` records progress and `pump_started` is set. That entry is
now a retained crossing. Later updates finish its handoff with zero offered
time even while paused, in order, without duplicating or replaying any
occurrence. This is how today's zero-delta tick finishes an entered frame. The
November 8 probe demonstrates it for both shipped zero-advancement paths, a
zero-delta tick and `speed = 0` with time offered: a frame zero with 70 cues
hands off 64 and then 6, with sequences 0–69 in order, while the frame stays 0.
The per-animation pause state itself is proposed and not implemented. A
`stop` that arrives mid-entry follows the stop table above (drain, then
reset).

**Editor pause.** labelle-studio Play mode skips the whole simulation half
while editor-paused. Boundary application and handoff therefore wait for the
next ticking update, and nothing is emitted in between (approved
`studio-preview-pause-scope`).

#### Dormant entry reconciliation (decision 16)

Approved decision 16 is "(a) same-entity predicate evaluated lazily on first
engine pass; (d) as v1 fallback" (proposed, not implemented). Specified:

- **Predicate.** A trigger entry may carry a reconciliation predicate (shown as
  `start_when` above). It reads only the same entity's component data (a
  boolean field, `"Comp.field"`) or game state (`"state:<name>"`). Cross-entity
  predicates are outside v1, because sibling entities have no ordering
  guarantee at entry. Exact syntax is schema work.
- **When it is evaluated.** Once, on the first engine animation pass after the
  entity appears: spawn, scene load or save restore. It is not evaluated in
  `onReady`/`postLoad`. Those fire per entity before later siblings
  (`HOOK-DELIVERY-CONTRACT.md` §11), and `loadGameState` respawns prefabs
  before it restores saved component data. The first pass afterwards sees
  restored state.
- **Effect.** If the predicate holds, that entry's command is queued at the
  command boundary exactly as if its event had fired. It then follows
  decisions 3–5 and emits frame zero once. If it does not hold, the clip stays
  dormant and waits for the edge event.
- **Latch.** The evaluation is once-only per attachment. Prefab refresh
  re-applies transient keys and resets the clip to dormant
  (`prefab_refresh.zig:351-358`), so it re-arms the latch. When the saveable
  playback sibling (decision 12) restores a non-dormant state, that restored
  state is authoritative and the latch is treated as consumed.
- **Fallback (d).** A clip whose initial state no predicate can express uses
  edge-only dormancy. The game must emit an initial event after scene
  readiness or restore. This is option (d) as listed in the round-1 review
  ("v1 documents edge-only dormancy and requires games to emit initial
  events", #794 comment 6713132800 and the author option list in comment
  6713999997).

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
persistence where continuity matters. **Approved decision 12 keeps it
transient.** Continuity lives in a separate saveable playback-state component
that lands with triggers. Making `SpriteAnimation` itself saveable was the
unchosen alternative. The author option list framed 12(a)/(b) as stages; the
review's version of the same options reads "making SpriteAnimation itself
saveable" (#794 comment 6713999997). It fails for two reasons:

- Live prefab reload (`src/jsonc/scene_loader/prefab_refresh.zig:484-487`)
  refreshes only transient types, so a saveable `SpriteAnimation` would
  silently stop refreshing.
- `frames`, `definition`, `clip` and `markers` are borrowed slices the
  serializer cannot write (`animation/src/sprite_animation.zig:67-75`;
  `src/game/save_load/save.zig:25-31`).

The sibling instead persists the playback state and re-binds `SpriteAnimation`
from its definition and clip on restore. Because refresh skips saveable
components, the sibling survives refresh unchanged and needs an explicit
post-refresh restore. The full list of what it must hold is under decision 12
in the POC section. The sibling must save clip, playback position and residual time,
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
`target_id` identifies the animation attachment. Engine-allocated identities
come from a per-game `u64` counter (`nextAnimationIdentity`) that ECS/world
resets do not touch, so within one `Game` instance the engine never allocates
the same id twice (demonstrated). The shipped guarantee stops there. It does
not make every cue's identity unique, and it does not drop every stale cue:

- `bindSpriteAnimation` keeps a nonzero authored `marker_target_id`
  (`src/game/animation_runtime_mixin.zig:94`).
- Script `labelle_component_set` bypasses binding entirely
  (`src/script_contract.zig:1517-1541`).
- `isAnimationMarkerTargetAlive` compares only `target_id`, never `playback_id`
  (`animation_runtime_mixin.zig:56-61`).

`playback_id` changes on every bind, including `selectSpriteAnimation`, and
`sequence` is unique within a playback. Native/flow hook delivery
(`src/game/events_mixin.zig:71-76`, `deliver`) drops a queued
`engine__anim_marker` cue when `isAnimationMarkerTargetAlive` fails. It filters
no other event and does not compare `playback_id`. Hooks must recheck liveness
before acting, and must compare `playback_id` whenever only the current
playback should act.

Delivery gaps (demonstrated at `be0991e`). First, `engine.script_contract.drainEvents`
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
(`src/root.zig:487-521`, `src/sprite_animation_tick.zig:132-141`). The November
8 probe shows the effect: after the component is removed, already-queued
`engine__anim_loop` events still reach hooks. **Approved decision 9
(proposed):** numeric and lifecycle cues get an internal attachment guard. The
engine records the attachment identity in queued-event metadata at enqueue and
validates it at delivery; public payloads are unchanged.

Gap: `marker_target_id` and `marker_playback_id` are ordinary struct fields,
so the prefab deserializer accepts them from JSONC, and `bindSpriteAnimation`
keeps a nonzero authored `marker_target_id` instead of allocating one
(`animation_runtime_mixin.zig`, `if (anim.marker_target_id == 0)`). Two
prefabs authoring the same value, or a prefab reusing a value from a destroyed
entity, weaken the reuse guard. `animation/MARKERS.md` only advises against
copying identity fields. **Approved decision 2 (proposed)**, in order of
precedence:

1. *Reject.* Prefab and script JSON that authors a nonzero `marker_target_id`
   or `marker_playback_id` fails closed under decision 1, so the component is
   not attached.
2. *Reset.* For input that passes validation, the prefab and script entry
   points zero both fields before binding, so the engine always allocates.
   This includes paths the validator does not see, and it happens before live
   prefab refresh copies the installed attachment's `marker_target_id` back
   (`src/jsonc/component_apply.zig:211`).
3. *Not inside `bindSpriteAnimation`.* The reset cannot live there, because
   `selectSpriteAnimation` also binds and must keep its target.

Zig gameplay code that writes the fields directly, or copies a
`SpriteAnimation` value between entities, can still forge an id. Approving
2(b) over 2(c) accepted that residual: the option text stated that the side
table of 2(c) "is worth it only if code-level forging matters". Such writes
are documented as unsupported (`animation/MARKERS.md`).

Marker authoring: `markers: [{ "name", "frame" }]` per clip, zero-based
frame indices, unique nonempty names per clip, at most 256 per clip, authored
order kept for equal frames.

Gameplay handlers interpret the cue and construct any domain events. For
example, an attack's `contact` cue lets gameplay inspect the current target,
weapon and attack validity before emitting a damage-related event; a `footstep`
cue can simply request a sound. The animation does not invent gameplay payloads.

Direct mappings from prefab marker declarations to arbitrary existing custom
GameEvents are outside v1. This is consistent with the named metadata already
produced by AnimationDef and can form a shared marker contract. Approved
decision 11: marker-specific subscriber indexes are deferred. In v1 every
`engine__anim_marker` subscriber receives every cue, and the 1/100/1,000-entity
benchmark is the gate for adding indexes later. The identity resolution and
retention mechanism must be specified alongside the event metadata
integration.

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
| Frame 0 on start/restart | Emit once at the animation command boundary for playback that starts/restarts after applying the batch. Resume and restoration do not replay it. Intermediate commands superseded in the batch do not emit transient cues. Decision 5(a): restart → pause emits once under the restart identity and the pause then holds; restart → stop emits nothing (section 3, "Frame zero under pause"). |
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
original playback identity. Restart/clip replacement creates a new identity,
and stop retires the current one (section 3, "Stop, retained crossings and
delivery validity");
hooks decide whether the earlier action still applies. Discard a marker if its
target no longer exists, including world/generation invalidation, rather than
retargeting a recycled entity. What is implemented, and its limits:

- A rebind keeps crossed markers under their original playback identity
  (`selectSpriteAnimation`; test `rebind keeps crossed markers original
  playback identity`).
- Discarding a removed or reset attachment's cues applies only to
  `engine__anim_marker` on the native/flow path. It relies on engine-allocated
  `target_id` values, which the gaps above qualify.
- Prefab refresh is refused, not queued, while a cursor is pending
  (section 3).

Cross-entity order: approved decision 10 accepts ECS traversal order for v1,
documented as backend-dependent. No backend-independent total order is
promised.

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

**Reconciling local pause with approved decision 13.** Decision 13 governs the
*global* inputs:

- the `paused` flag gates scaled clips;
- `time_scale == 0` freezes scaled clips without a pause transition;
- the subsystem-wide `sprite_animations_paused` flag is removed in the major
  release.

It does not remove the agreed independent local pause, because that pause is
not a global input. It is the per-animation paused playback state that the
`pause` action sets and that `resume`, or `play` of the same clip, clears (see
the action table). The combined gates (proposed) are:

```text
local_paused  = this playback's paused state (action table)
editor_paused = labelle-studio Play mode with shouldTick() == false
scaled dt   = real dt * (editor_paused or local_paused or game_paused ? 0 : current_game_speed) * animation_speed
unscaled dt = real dt * (editor_paused or local_paused ? 0 : 1) * animation_speed
```

The local pause is independent of game pause in both directions. Game pause
never sets or clears it, and it freezes both scaled and unscaled clips. It is
also not `speed = 0`, which is a per-animation speed multiplier rather than a
playback state. Both stop advancement, and neither cancels the handoff of a
frame entered at the command boundary (section 3, "Frame zero under pause").
Stopped and dormant suppress frame-zero entry until playback starts.
Decision 6's pre-validation hold and editor pause defer it, and it is emitted
once when they lift (section 3, "Frame zero under pause"). A zero-speed
clip spawned fresh still emits its frame-0 markers on the first tick
(`animation/test/animation_package_test.zig:206-233`, entity `b`).

This reconciliation implements approvals rather than adding one:

- The agreed September items "pause/resume position preservation" and
  "independent pause and speed settings" (readiness list, checked) define the
  per-animation pause.
- Approved decision 13(b) defines the global inputs.
- The option that revised the independent pause was not chosen. In the author
  option list it is (c): "time_scale == 0 only, as proposed on July 20,
  revising the independent local-pause requirement" (#794 comment 6713999997).
- The owner's approval record asked for exactly this reconciliation. Commit
  `55acd26` lists "reconciling the accepted pause recommendation with
  independent local animation pause" as a required review correction, and
  comment 6714122754 says "The pause-contract inconsistency … still need
  correction".
- It is not option 13(d). (d) had "neither global flag touches animation
  directly"; here the global `paused` flag still gates scaled clips, as 13(b)
  requires. The November 7 POC prototyped the global inputs only,
so its decision 13 table has no per-animation row. This combination has not
been prototyped.

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

The subsystem-wide pause API (`setSpriteAnimationsPaused` /
`sprite_animations_paused`) is removed in the major release under approved
decision 13. Until then it keeps today's behavior. No undocumented
compatibility clock replaces it; the per-animation pause above is the local
pause. The POC's statement that the flag "has no non-test users" holds only
inside the engine repository. Flying Platform `main` (`dab1b10f`) calls
`setSpriteAnimationsPaused` from its pause menu
(`scripts/playing/97_pause_menu.zig:273`) and reads the flag in
`packs/sky/scripts/playing/38_ceiling_lighting.zig:346` (demonstrated). The
removal therefore needs that consumer migration. Nothing in this section is
implemented on main; an `update` key on the component is silently ignored by the struct
deserializer today, not rejected (section 2, "Expansion contract"), so the
rollout needs the same unknown-key diagnostic as triggers.

A third loop variant is affected: under labelle-studio Play mode a paused
iteration fails `shouldTick()` and skips the whole SIM half, drains and
`g.tick` included (`HOOK-DELIVERY-CONTRACT.md` §2). Editor pause is separate
from `game.paused`, so under every pause option even unscaled clips freeze in
Play mode. Moving unscaled advancement outside the `shouldTick` gate to keep
the "unscaled keeps running" promise makes the event buffer grow without bound
there (351 undrained events after 401 iterations in the November 7 POC;
reported). The
owner-approved migration explicitly freezes all preview animations during editor pause, including unscaled clips. Keep their advancement inside the editor simulation gate; do not move it outside merely to preserve runtime unscaled behavior. Runtime game pause retains the scaled/unscaled distinction.

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
`be0991e`. Each POC was reported to keep the full `zig build test` suite green
unless noted. The POC branches (`poc/794-command-boundary`, `-trigger-shape`,
`-readiness-refresh`, `-validation-identity`, `-delivery-scale`,
`-clock-ownership`) were local to the session that wrote `2513e3f`, and none of
them is a proposed implementation.

**Availability (November 8).** None of the branches can be found: not in any
local clone of the engine repository, not on `origin`, not on the CI host, and
not in the review pipeline's container. No file anywhere contains POC-only
identifiers such as `pendingPumped` or `engine__anim_refresh_applied`. The POC
code, test runs and benchmarks therefore cannot be inspected or re-run. Every
POC number below is *reported* unless the "November 8 revalidation" subsection
marks it otherwise.

**Owner approval recorded on November 7, 2026:** the owner explicitly approved
all 17 recommendations in the summary below ("The recommendation are approved
by me"), referring to the POC recommendations in PR head `2513e3f593015526cc832d247fdbf6f8bdc2f0f6`.
The summary entries are now accepted design directions, not unanswered owner
choices. Options are lettered as in the review comment; the POC evidence and
limitations below remain unchanged.

This approval does not approve implementation, and it does not certify the POC
results as independently reproduced. The owner also approved the review's three
additional questions on November 7 (recorded below). The November 8 revision
applies the review's technical corrections without reopening any of the 20
decisions:

- local pause is reconciled with decision 13 in section 5;
- stale "open decision" wording is removed;
- document provenance is corrected in "Status and scope";
- POC accounting and scope limits are recorded below.

Applying an approved recommendation never drops an agreed requirement.

### Additional owner-approved decisions (November 7, 2026)

After the 17 POC recommendations, the owner approved the following recommendations
with "Go with your recommendations":

| Decision | Approved behavior |
| --- | --- |
| `stop-playback-identity` | Stop invalidates the playback identity; queued cues from the stopped playback cannot affect a later playback. |
| `remaining-playback-actions` | `play` resumes paused playback of the same clip. `resume` is a no-op for stopped/completed playback; explicit `play` starts those again. Mode changes preserve the current position and apply going forward. |
| `studio-preview-pause-scope` | Editor pause freezes all preview animations, including unscaled ones. Runtime game pause retains the scaled/unscaled distinction. |

These are accepted behavioral decisions. They are not evidence that
implementation or tests are complete. Section 5 reconciles them with the
independent local pause, and the action table and section 5 carry them.
Implementation approval has not been granted.

### Summary

The "Approved recommendation" column is the approved text, verbatim. In row 2,
"(1)" refers to option (a), rejecting authored values (see section 4). The "Deciding
evidence" column summarizes November 7 POC results. Those are *reported*
unless the November 8 revalidation marks them demonstrated (decision 7's
removal row and decision 13's consumer note).

| # | Decision | Approved recommendation | Deciding evidence |
| --- | --- | --- | --- |
| 1 | `prefab-validation-boundary` | (c) assembler diagnostics + engine fail-closed backstop | Assembler-only misses runtime JSONC, studio hot-push, `labelle_component_set` and Zig-built components |
| 2 | `identity-fields-authoring` | (b) reset at authored-data entry points, plus (1) rejecting authored values | Forged `marker_target_id` lets a stale cue reach a hook today |
| 3 | `unpumped-initial-cursor` | (a) unpumped cursor is replaceable | (b) emits transient cues **and deadlocks** stopped/dormant cursors |
| 4 | `queued-command-vs-pending-cursor` | (b) drain within budget, else stall (a) | Neither loses cues; plain stall plays the replaced clip one extra update |
| 5 | `frame-zero-conflicting-batches` | (a) | (b) needs a persisted "deferred frame zero" state; (c) emits a transient cue |
| 6 | `pre-readiness-playback-policy` | (b) hold, plus an explicit host "assets ready" call | Today an invalid clip's queued cue is delivered and the clip never recovers |
| 7 | `blocked-refresh-retry-owner` | (a) engine parks and applies, **including removal** | Removal today delivers none of the 267 backlog marker cues, yet still delivers queued loop events (demonstrated, November 8) |
| 8 | `script-drain-liveness` | (a) filter in `drainEvents` | (b) breaks 4 shipped hook-delivery tests |
| 9 | `legacy-cue-identity-scope` | Internal enqueue-time attachment guard for numeric and lifecycle cues | (c) misdelivers to a reused ID; marked-clip `engine__anim_complete` reaches a replacement today |
| 10 | `cross-entity-marker-order` | (a) traversal order, documented | Sort adds ~25 ns/cue and is deterministic but not chronological |
| 11 | `marker-subscriber-indexes-v1` | (b) defer | 1,000 cues × 50 subscribers ≈ 96 µs/frame (~0.6% at 60 fps) |
| 12 | `persistence-owner-stage` | (c) transient SpriteAnimation + saveable sibling, **landing with triggers** | Load and refresh silently revert a triggered prop today |
| 13 | `local-animation-pause-input` | (b) `paused` gates scaled clips; subsystem flag removed | Only (b) matches the agreed clock model. The flag has no non-test users *in the engine*; Flying Platform uses it, so its removal needs migration (demonstrated). How the agreed per-animation pause coexists with (b) is a reconciliation in section 5, not part of the approved text |
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

Owner decision (November 7): `stop` invalidates the stopped playback identity; stale queued cues from it must not affect a later playback. This resolves the identity choice that the POC assumed.

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
  an equal alternative. The POC also suggested that script
  `labelle_component_set` on SpriteAnimation return a retry code (`-2`) while
  the cursor is pending. That note is not part of the approved recommendation.
  Under decision 7 such a set is parked like any push (section 3).

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
  `TextureManager.version` (`src/atlas.zig:226`) and was reported to work in
  the test. Its limits:
  - Each failed retry logs an error (reported).
  - `invalidateAtlasBinding` bumps `version` when it re-arms a loaded atlas. It
    returns early with no bump when the atlas is unknown, has no retained
    image, or is already pending (`src/atlas.zig:489-496`, demonstrated).
    Repeated per-tick calls for an already re-armed atlas therefore produce no
    further version change, by design (engine#821). Revalidation keyed on
    `version` sees the first re-arm, not every call.
  - An unloaded atlas does not re-hold a clip that already passed (reported).

  Revalidation is not part of approved decision 6; it is a follow-up.
- **7.** A 336-crossing backlog, then a prefab push:

  | Push | Policy | Applied | Marker cues delivered |
  | --- | --- | --- | --- |
  | Replace | today | never | 285 |
  | Replace | (a) engine parks | frame 6 | 304 + completion event |
  | Replace | (b) result code | never | 285 |
  | Remove | today | immediately | **0** |
  | Remove | (a) engine parks | frame 6 | 268 + completion event |

  **Accounting.** The November 8 probe demonstrates this for the shipped rows
  and the emulated outcome; the parked rows themselves are reported. 336 is
  not a count of marker cues. The POC fixture matches the shipped test `prefab
  refresh preserves pending crossings`: a 3-frame loop with markers on frames 0
  and 1, at 4 fps, spawned with a zero-delta tick and then given `tick(100)`.

  - 100 s × 4 fps = 400 entered frames: 267 marker cues and 133
    `engine__anim_loop` events.
  - The first update hands off 64 of them, so **336 = 400 − 64 occurrences of
    both kinds stay in the cursor**. Without the spawn-frame tick, the first
    pump also carries the frame-zero cue and 337 remain.
  - The table's delivered column counts only `engine__anim_marker` receipts.
    A full drain delivers 268 marker cues (the 267 backlog markers plus the
    spawn-frame `start` cue, i.e. every marker of the old playback) and all
    133 loop events.

  So 268 for parked removal is complete delivery, not 68 lost cues. The probe's
  drain-then-remove emulation reproduces exactly 268 markers and 133 loops.
  304 for parked replacement is consistent with those 268 plus 36 markers of
  the new playback within the POC's observation window. The probe's
  drain-then-replace run gives 268 + 8 in a 10-update window, so the new count
  depends on the window, and 304 itself stays unverified. 285 for today's
  refused replacement counts old-playback cues while the old clip keeps
  playing; it is also window-dependent and unverified. None of these numbers
  shows a lost marker cue. The probe also shows that today's removal still
  delivers the 21 already-queued loop events (see decision 9).

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
  filter checks only `engine__anim_marker` (reported). The November 8 probe
  independently demonstrates the same filter gap without any ID reuse: after
  `SpriteAnimation` is removed, 21 already-queued `engine__anim_loop` events of
  the removed attachment still reach hooks. The guard records
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

  Today `setPaused` freezes no sprites, and (d) keeps that. `speed = 0` is a
  speed multiplier, not the playback pause state. (d) adds a pause that keeps the speed value and can layer on
  (b) later. Within the engine repository, `sprite_animations_paused` is
  referenced only by engine tests. Flying Platform uses it (section 5).
  The approved design (b) and the per-animation paused state of the action
  table together give the agreed model (section 5). The POC did not prototype
  that combination, and its table has no row for it.
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
  `game.zig:1822`). Dotted names carry the plugin import name
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
  Section 3 now states the approved rule; it replaces the September "dotted is
  the recommended spelling".
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

  **What the prototype lacked, and how the approved design meets the agreed
  preservation requirements (proposed).** The prototype restored clip, frame,
  elapsed time and playing state. It lost:

  - the retained crossings (`steps`, `loop_pending`, `complete_pending`);
  - the occurrence counter (`sequence`);
  - the frame-zero entry state (`entering`, `marker_index`, `pump_started`);
  - the playback identity.

  Decision 12 chooses a representation and a stage; it does not narrow the
  agreed readiness item "saved playback/marker progress, pending cue
  preservation with entity remapping, no historical marker replay". The sibling
  must therefore:

  1. **Persist the whole `MarkerCursor` value.** It holds only integers,
     booleans and one `f64`, and it round-trips through labelle-core `serde`
     v2.2.0 mid-backlog (demonstrated: `steps = 334`, `sequence = 65`,
     `entering`, `loop_pending`). `serde` writes floats with six decimals, so
     `remainder_seconds` either needs an exact encoding or a bounded-error
     argument. Restore validates `frame` and `marker_index` against the
     re-bound clip and fails closed on a mismatch.
  2. **Persist `marker_target_id` and `marker_playback_id`, restore them
     without minting, and reserve them.** Today every bind mints a new playback
     id (`animation_runtime_mixin.zig:95`), so restore needs its own rebind
     path. That path is an engine-owned identity write, not authored data
     (decision 2). Restored ids must not collide with ids the restoring `Game`
     allocates later. The counter starts at 0 in a fresh `Game` (`src/game.zig:799`)
     and is unrelated to the saving `Game`'s counter. Restore therefore raises
     `animation_identity` above the largest restored id. Load must also
     invalidate pre-restore delivery state: `loadGameState` resets the ECS but
     does not clear `game.event_buffer` (it never calls
     `clearPendingSceneEvents`; `src/game/save_load/load.zig:549`, inspected),
     so cues queued before a load into a live `Game` could otherwise match a
     restored id. Saved occurrence identity (point 3) is preserved. Because
     the sibling is a registered component, authored data (prefab JSONC,
     script set) must not be able to write its identity or cursor fields
     (readiness, fail-closed item).
  3. **Cover occurrences already handed off to `game.event_buffer`.** They are
     outside the component (the probe shows 64 queued while the cursor holds
     the rest). Either put the save boundary after the drain, so no animation
     event is queued at save, or save the queued animation events of saved
     entities and remap their generation-checked entity references on restore.
     This is the agreed "atomic save/queue handoff" item.
  4. **Never replay.** Restored `entering`, `marker_index` and `sequence` keep
     the frame-zero cue and every delivered occurrence from being emitted
     again.
  5. **Store the clip by an identifier that survives a rename.** The
     prototype's name hash fails on rename. Core `serde` cannot write strings
     today: `writeComponent` compile-errors on pointers and slices
     (`serde.zig:64`, demonstrated).
  6. **Copy live state into the sibling at save, and restore it after load and
     after refresh.** The engine has no pre-save hook (demonstrated by search).
     Decision 7's `engine__anim_refresh_applied` signals only parked
     refreshes; an unblocked refresh still needs its own completion point.

  None of points 1–6 has been prototyped end to end.

### November 8 revalidation

The POC branches are unavailable, so this round re-ran only what the shipped
code can show. Revisions: engine `be0991eabf5ff4bf75700ceab7bfc2365c7ce22b`,
labelle-core `85b554627ee050ccd56c5b4a5f51902e8b7a7e2a` (v2.2.0, the last core
`main` commit before `be0991e`, used as the sibling `../labelle-core` exactly as
CI does), Zig 0.16.0. The probe source, build patch, command lines and full
output are in
[`docs/investigations/rfc-793/poc-794/`](docs/investigations/rfc-793/poc-794/README.md).

| Check | Command | Outcome |
| --- | --- | --- |
| Shipped animation tests | `zig build test-animation --summary all` | 21 pass (21 total), including the refresh test that asserts 268 (`poc-794/test-animation.log`) |
| Refresh/removal accounting | `zig build test-rfc794-probe`, then the test binary run directly | passes. Measured: 64 handed off, cursor `steps = 334` with `entering`/`loop_pending` set, 268 markers and 133 loops delivered on a full drain; today's removal delivers 0 backlog markers and 21 queued loop events. Derived from those: 400 = 267 + 133 occurrences, 336 retained (asserted as `(markers − 1) + loops − 64`), and 43 queued markers dropped by liveness (64 − 21) |
| Frame-zero handoff over budget without advancing | same probe | 64 then 6 handoffs (70 cues), sequences 0–69 in order, frame stays 0, under both a zero-delta tick and `speed = 0` |
| Cursor persistence | same probe | `MarkerCursor` round-trips through core `serde` mid-backlog; the 64 queued events stay outside it |
| `invalidateAtlasBinding` version | code read, `src/atlas.zig:489-496` | bumps on re-arm; no bump on early return |
| Stale-event scope | code read, `animation_runtime_mixin.zig:56-61,94`, `events_mixin.zig:71-76`, `script_contract.zig:533-540,1517-1541,1790-1797` | marker-only, `target_id`-only filter on the native/flow path |
| Subsystem pause users | `git grep` at Flying Platform `dab1b10f` | two consumer uses (section 5) |

Not re-run, and still *reported*: every other POC number in this section,
including the decision 3–5 counts, the decision 6 table, 304 and 285 under
decision 7, the decision 9–11 benchmarks, the decision 15 test count and the
decision 12 prototype.

## Decision audit (November 8, second pass)

The review of `a5dd7f8` raised five items as possible owner decisions. Each is
classified here:

- **A**: resolved by an explicit owner approval or an agreed requirement;
- **T**: a technical or documentation correction;
- **N**: a genuinely new product decision.

| Item | Where it came from | Class | Basis and result |
| --- | --- | --- | --- |
| `stale-playback-cue-filtering` | Committed `a5dd7f8` (then "ambiguity 1") | A | Approved `stop-playback-identity`, the agreed interruption rule (section 4) and the agreed delivery contract ("Hooks … must validate the entity and action at delivery. Playback identity allows rejection of an old attack's cue after interruption"). Queued cues of a stopped playback are delivered with the retired id; the engine enforces attachment validity and hooks enforce playback validity (section 3, "Stop, retained crossings and delivery validity"). The earlier author recommendation (c) is withdrawn. |
| `stop-retained-crossings-disposition` | Review of `a5dd7f8`, against the committed stop row and the withdrawn recommendation | T | The agreed no-drop and interruption rules, approved decision 4's drain and the agreed stop reset compose without conflict: drain under the stopped identity (stalling when the budget runs out), then reset. An unpumped entry is discarded (decisions 3 and 5(a)). |
| `parked-removal-window-behavior` | Committed `a5dd7f8` (then "ambiguity 2") | T | See the rule table below. |
| `code-level-identity-forging` | **Introduced by the pipeline's author rewrite**; not in any commit | A | Approved decision 2(b) was chosen over 2(c) with the residual stated in the option ("Zig gameplay code can still forge an id under (b)"). Direct writes and struct copies are unsupported. The persistence restore path is a deliberate engine write (decision 12, point 2). |
| `local-pause-under-decision-13b` | Review of `a5dd7f8`, against the committed summary row | T | The agreed September items (pause/resume position preservation; independent pause and speed settings) plus approved 13(b). The revising option ((c) in the author list) was not chosen, and the owner's `55acd26` record requested this reconciliation as a correction. It is not 13(d), because the global flag still gates scaled clips. The summary row no longer places the reconciliation in the approved column (section 5). |

`parked-removal-window-behavior` follows from these existing rules:

| Rule | Source | Consequence while the removal is parked |
| --- | --- | --- |
| The engine parks the push, keeps the latest push per entity, applies it after the drain and emits a completion event | Approved decision 7(a) | A later set of `SpriteAnimation` supersedes the parked removal. `engine__anim_refresh_applied` also fires for removals. |
| A pending cursor accepts no new time | Shipped backpressure (section 4) | The animation stays frozen on its current frame. |
| Visibility is separate state | Agreed (section 3, action table) | It is neither hidden nor shown differently. |
| Per target, the boundary drains, then applies the parked push, then applies commands in dispatch order with lifetime validated at application | Agreed targeting and command rules; decisions 4 and 7 (section 3) | After the removal applies, commands queued for that target find no attachment and are skipped. A script set during the window is a push, and the latest push wins. |

`hasComponent` stays true until the removal applies; that is a specification
detail.

**Result: none of the five items needs a new owner decision.** No item
reopens any of the 20 approvals.

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
- [x] Owner-approved design decisions (November 7): the 17 POC
  recommendations (summary table) plus `stop-playback-identity`,
  `remaining-playback-actions` and `studio-preview-pause-scope`. These are
  design approvals only. They are not implementation, merge or deployment
  approval, and they do not certify the POC measurements.
- [ ] Specify the trigger JSONC schema for the `AnimationTriggers` sibling
  (decision 14), clip speed and transition fields, the typed payload-to-target
  adapter APIs and the binding/state layout. The command boundary must
  implement the approved rules:
  - an unpumped initial cursor is replaceable (decision 3);
  - drain within budget, otherwise stall (decision 4);
  - frame-zero handling for conflicting batches (decision 5);
  - stop identity invalidation and the action table's play/resume/mode-change
    rows;
  - `stop` and `start: "dormant"` suppress frame-zero entry on zero-delta
    ticks.

  (Definition/marker schema, grammar limits and package wiring are done.)
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
  preservation). Required before `triggers`, `start`, `update` or `drive`
  ship, so pre-rollout authoring cannot load silently or corrupt playback.
  `AnimationTriggers` keys get the same treatment when that component ships.
  The saveable playback sibling (decision 12) gets it too. Its identity fields
  and cursor state are engine-written only (save copy and load restore), so
  prefab JSONC and script set must reject them, or it would reopen the forging
  path that decisions 1 and 2 close.
- [ ] Specify dormant entry reconciliation per decision 16: the same-entity
  predicate syntax on `AnimationTriggers`, first-pass evaluation, the
  once-only latch re-armed on refresh and consumed by a restored non-dormant
  state, and the edge-only fallback (d) (section 3, "Dormant entry
  reconciliation").
- [ ] Specify persistence per decision 12. `SpriteAnimation` stays
  `.transient`; a saveable playback sibling lands with triggers and must meet
  points 1–6 under decision 12 in the POC section: full cursor state,
  identities restored without minting, atomic save/queue handoff with entity
  remapping, no replay, a rename-safe clip identifier, and save/refresh copy
  points. The sibling survives `PrefabRefresh` because refresh skips saveable
  components, so it needs an explicit post-refresh restore.
- [ ] Specify and implement the approved delivery rules:
  - document traversal order (decision 10);
  - defer subscriber indexes behind the benchmark gate (decision 11);
  - filter liveness in `script_contract.drainEvents` (decision 8);
  - add the internal enqueue-time attachment guard for numeric and lifecycle
    cues (decision 9).

  Also specify and implement the approved readiness rules: pre-tick atlas
  validation ordering, hold-until-validated with a host "assets ready" call
  (decision 6), engine-parked refresh and removal including script
  `componentRemoveImpl` with a completion event (decision 7), and hot-reload
  identity and lifetime details. (Per-entity traversal backpressure is done.)
- [ ] Implement/test native and callback loop integration for the trigger
  command boundary and consumption ordering, implementing approved decisions
  3, 4 and 5.
- [ ] Implement/test the unscaled input migration in the native, callback and
  studio-preview loops, following section 5: `paused` gates scaled clips, the
  per-animation pause freezes both modes, and editor pause freezes all preview
  clips. Remove `sprite_animations_paused` with Flying Platform's pause-menu and
  ceiling-lighting migration. Verify single advancement with the per-instance
  `drive: engine | manual` opt-out (decisions 13 and 15).
- [ ] Re-run the four-reviewer pipeline on this revision. No reviewer has
  approved it.
- [ ] Re-establish the POC evidence that could not be re-run (see
  "Availability"), or keep treating those numbers as reported when
  implementation tests replace them.
- [ ] Demonstrate a real consumer pilot, including persistence and failure paths.

Recommended implementation order: shorthand (done); marker traversal and queue
handoff (shipped; the approved delivery-identity work of decisions 8 and 9 and
the documented ordering of decision 10 are outstanding);
triggers with a consumer pilot and playback persistence (persistence lands
with triggers, decision 12); pause migration; default driving.
Each has its own acceptance gate. The marker and trigger work shares the hooks
delivery/ordering contracts (`HOOK-DELIVERY-CONTRACT.md`, #857); the whole
hooks enhancement roadmap is not a prerequisite to the remaining stages.
