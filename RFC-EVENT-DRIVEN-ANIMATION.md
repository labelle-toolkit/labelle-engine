# RFC: Declarative, event-driven sprite animation

## Summary

Four incremental changes that let sprite animations be authored as **prefab
data** instead of per-game driver scripts:

1. **Drive animations by default** — retire the one-line opt-in every game
   copies (`00_sprite_animation_driver.zig`).
2. **Frame-range shorthand** — declare `sewer_machine_0001..0010` without
   listing all ten filenames.
3. **Event-triggered playback** — `"play once on event X"`, `"loop on event
   Y"`, `"stop on event Z"`, declared on the animation.
4. **Named + crossing-accurate frame markers** — `"emit footstep at frame
   3"`, firing a *named* game event (not a generic frame-index event) and
   never dropped by a `dt` spike.

Together they make animations **fully symmetric event participants** —
triggered *by* events and emitting *named* events at specific frames — so the
common cases need no `*_animation.zig` script at all.

## Motivation

Today, "make this sprite animate in response to the game" means writing a
per-feature Zig script. flying-platform alone carries ~10 of them:
`33_wc_animation.zig`, `worker_animation.zig`, `08_sleep_animation.zig`,
`bandit_animation.zig`, `ship_animation.zig`, `17_status_overlay.zig`,
`34_bowel_overlay.zig`, the kitchen smoke/sink overlay component + script,
`condenser_gate.zig`, … A large fraction of these are literally *"when
state/event X happens, play clip A once or on loop; when Y, stop."*

That's boilerplate the engine can absorb. The animation machinery is already
engine-side; what's missing is a **declarative binding** between the game's
event bus and animation playback — in both directions.

This also directly serves the toolkit's "Packs" / LLM-authoring goal: adding
an animated prop should be one prefab entry, not a component **plus** a script.

## Background: what already exists

Grounding the proposal in the current code (`labelle-engine/src`):

- **`SpriteAnimation`** (`sprite_animation.zig:51`) — a `.transient` component
  with `frames: []const []const u8`, `fps`, `mode: .loop | .once | .ping_pong`,
  `speed`, and `event_frames: []const u16`. It auto-plays on spawn.
- **The engine already advances it.** `game/loop_mixin.zig:86` ticks every
  `SpriteAnimation` on the time-scaled `dt`, gated on
  `drive_sprite_animations and !sprite_animations_paused and scaled_dt != 0`.
- **The flag defaults off.** `game.zig:723` (`drive_sprite_animations: bool =
  false`) — *"Off by default so existing projects that still drive animation
  from a script don't double-advance."* Hence every game copies a one-line
  `setDriveSpriteAnimations(true)` at boot.
- **Animations already EMIT events** (`animation_events.zig`): `engine__anim_
  complete` (once clips), `engine__anim_frame` (from `event_frames`, "landed
  on" semantics — v1 can miss a frame on a `dt` spike), `engine__anim_loop`.
  Delivered through the buffered event bus (`game.emit`).
- **`AnimationDef`** (`animation_def.zig`) — a richer clip/variant system with
  `TransitionRule { from: ?u8, to: u8, via: u8 }` and **crossing-accurate**
  markers via beat iteration.
- **Components already SUBSCRIBE to events** — the events-as-spine pattern the
  packs use (custom `events/*.zig` folding into `GameEvents`).

So animations already *produce* events and the bus already *routes* them; what
does not exist is animations *consuming* events declaratively, or emitting
*named* ones.

## Proposal

### 1. Drive sprite animations by default

The advance is already in the engine; the only game-side artifact is flipping
the opt-in. Make it unnecessary:

- **Default `drive_sprite_animations = true`.** The tick only iterates
  `SpriteAnimation` components — zero cost for games with none.
- The one thing this can break is a game *still* running the deprecated
  legacy `sprite_animation_tick` script (double-advance). Those get an
  explicit **opt-out** (`setDriveSpriteAnimations(false)`), and are expected to
  migrate. Consider a comptime alternative: the assembler enables the flag when
  the `SpriteAnimation` component is present in the registry and no legacy tick
  script is discovered — "if you use the component, it's driven."
- **Result:** `00_sprite_animation_driver.zig` disappears from every game.

Because it changes a default, land it behind the next engine **major**, or gate
on a project-config `animation.autodrive` that defaults on for new scaffolds.

### 2. Frame-range shorthand

Authoring an N-frame clip should not mean typing N filenames. Extend the
`SpriteAnimation` prefab deserializer to accept a pattern as an alternative to
`frames`:

```jsonc
"SpriteAnimation": {
  "frames_pattern": "sewer/sewer_machine/sewer_machine_%04d",
  "from": 1, "to": 10,
  "fps": 8, "mode": "loop"
}
```

- Expands to `..._0001.png … _0010.png` at load, interning the same strings
  `frames` would have.
- `frames` (explicit list) stays valid and takes precedence; `frames_pattern`
  is sugar. `%0Nd` width comes from the pattern; `.png` is appended if absent.
- Pure load-time expansion — no runtime cost, no change to the component's
  runtime shape.

### 3. Event-triggered playback

Let an animation declare which events start/stop it and how. New optional
`triggers` on the animation component (or a sibling `AnimationTriggers`
component if we want to keep `SpriteAnimation` save-shape frozen):

```jsonc
"SpriteAnimation": {
  "frames_pattern": "sewer/sewer_machine/sewer_machine_%04d", "from": 1, "to": 10, "fps": 8,
  "start": "dormant",              // don't auto-play on spawn
  "triggers": [
    { "on": "sewer__machine_on",  "play": "loop" },
    { "on": "sewer__machine_off", "action": "stop" },
    { "on": "sewer__pulse",       "play": "once" }
  ]
}
```

Vocabulary:

- `play`: `once` | `loop` | `ping_pong` — (re)start the clip in that mode.
- `action`: `stop` | `pause` | `resume` | `restart`.
- `start`: `playing` (today's behavior, default) | `dormant` (wait for a
  trigger) — so triggered props don't run until their event arrives.

This is resolved by the same driver that already advances animations; it reads
the frame's event buffer and applies matching triggers before advancing.

#### Entity targeting (the crux)

Events are global; a `machine_on` must start *the machine in the room that
turned on*, not every sewer. This is the real design decision, not the syntax.
Two rules, pick one (or support both):

- **Self-scoped (default):** an animation reacts only to events emitted *about
  its own entity* (or an ancestor — the room). The event carries an entity id;
  the trigger matches when that id is the animation's entity or a parent. This
  mirrors exactly what the imperative scripts do today (walk `parent → child by
  sprite_name`).
- **Broadcast (opt-in):** `{ "on": "...", "scope": "any" }` reacts to the event
  regardless of target — for genuinely global cues (a day/night tint pulse).

Recommendation: **self-scoped by default**, `scope: "any"` to opt out. Getting
this right is what makes the feature replace scripts instead of adding footguns.

### 4. Named + crossing-accurate frame markers

`event_frames` already fires at frames, but fires one *generic*
`engine__anim_frame` carrying the index — so every consumer filters `if (frame
== 3)`. Let the marker name the event it emits:

```jsonc
"markers": [
  { "frame": 3, "emit": "footstep" },
  { "frame": 7, "emit": "sewer__splash" }
]
```

- Emits the *named* event through `game.emit`, carrying the animation's entity
  as target (so consumers can scope it, same as §3).
- **Crossing-accurate by default.** `SpriteAnimation.event_frames` is v1
  "landed-on" (a lag spike past frame 3 misses it, per its own doc comment);
  `AnimationDef` already does crossing-accurate via beat iteration. The named-
  marker path should use crossing detection so a footstep/hit never silently
  drops. Keep the legacy `event_frames` field working (landed-on) for compat.

## The combined model

Put §3 and §4 together and animations become event-symmetric, entirely in data:

```
game event ──trigger (§3)──▶  [ animation clip ]  ──marker (§4)──▶ named game event
                                    ▲     │
                          AnimationDef transitions (existing)
```

- **In:** "play once / loop / stop on event X" (declarative — new)
- **Out:** "emit `footstep` at frame N" (marker — exists, upgraded to named +
  crossing-accurate)
- **Sequencing:** `AnimationDef` `TransitionRule` for state cases (existing)

Add §1 (default-on) and §2 (shorthand) and authoring an animated prop goes from
"a component **plus** a script" to a single prefab entry.

## What this does NOT replace

Be honest about the ceiling. Event-triggers + markers cover *"play/stop a clip
on an event, and emit cues."* They do **not** replace true state machines that
choose direction/target frame from current runtime state — e.g.
`33_wc_animation.zig` plays the door **forward or reverse depending on the
current frame** and flips a screen colour. Those belong in `AnimationDef`
transitions (`from → to via`); the trigger just *requests* a target clip and the
transition table decides the path. The RFC composes with that system, it does
not duplicate it. Worker locomotion, death, and status overlays that derive the
clip from continuous component state also stay script/`AnimationDef`-driven.

Rough estimate on flying-platform: of the ~10 `*_animation.zig` scripts, the
machine/smoke/overlay/gate family (~half) collapses to prefab data; the
worker/wc/state-machine family stays but shrinks (markers replace their manual
frame bookkeeping).

## Compatibility & migration

- **§2 / §3 / §4** are strictly additive (new optional fields / a new sibling
  component). Existing prefabs are untouched.
- **§1** changes a default → next major, or a `animation.autodrive` project
  flag defaulting on for new scaffolds, off for pre-existing ones until they
  drop their legacy tick script.
- Keep `event_frames` (landed-on) as a deprecated alias of the new named-marker
  path so #625 consumers don't break.

## Open questions

1. **Component boundary:** extend `SpriteAnimation` (it's `.transient`, so no
   save-shape cost) vs. a separate `AnimationTriggers` / `AnimationMarkers`
   sibling? Separate keeps each concern small and lets `AnimationDef` reuse the
   trigger/marker parsers.
2. **Targeting default:** self-scoped vs. broadcast — confirm self-scoped is the
   right default and specify how the "about my entity/ancestor" match reads the
   event payload.
3. **Trigger → AnimationDef bridge:** for `AnimationDef` entities, does a
   trigger name a *clip* (letting transitions handle the `via`), or a raw
   frame range? Naming a clip is the composable answer.
4. **Marker payload:** do named markers carry extra data (a `value` field) or
   just the entity + event name? Start with entity + name; add payload if a
   consumer needs it.
5. **Dedup / re-trigger semantics:** if `machine_on` fires while already
   looping, is it a no-op or a restart? Propose no-op for `loop`, restart for
   `once`.

## Rollout

Independent, shippable in order:

1. §2 frame-range shorthand — smallest, immediate authoring win, zero risk.
2. §4 named + crossing-accurate markers — additive; upgrades #625.
3. §3 event-triggered playback + targeting — the main feature.
4. §1 default-on driver — the breaking-default cleanup, batched into a major.
