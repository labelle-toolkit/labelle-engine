# RFC #794 POC evidence: November 8 revalidation

This directory holds what a later reviewer needs to check the POC claims that
`RFC-EVENT-DRIVEN-ANIMATION.md` relies on. It contains no credentials or
consumer data.

## Availability of the November 7 POC branches

The RFC cites six local branches: `poc/794-command-boundary`,
`poc/794-trigger-shape`, `poc/794-readiness-refresh`,
`poc/794-validation-identity`, `poc/794-delivery-scale` and
`poc/794-clock-ownership`. On November 8 none of them could be found:

- no `refs/heads/poc/794*` (or reflog entry) in any local clone or worktree of
  `labelle-engine` on the author's workstation, and no such ref on `origin`;
- none in any git checkout on the CI host or inside the review-pipeline
  container;
- no file anywhere on those machines contains POC-only identifiers such as
  `pendingPumped` or `engine__anim_refresh_applied`.

The POC code, its test runs and its benchmark numbers therefore **cannot be
re-executed or inspected**. The RFC labels every such number *reported*.

## What was re-run

Revisions: engine `be0991eabf5ff4bf75700ceab7bfc2365c7ce22b` (the POC base),
labelle-core `85b554627ee050ccd56c5b4a5f51902e8b7a7e2a` (v2.2.0: the last core
`main` commit before `be0991e`, checked out as the sibling `../labelle-core`
exactly as CI does), Zig 0.16.0 (`minimum_zig_version`).

1. Shipped tests: `zig build test-animation` → `21 pass (21 total)`. That run
   includes `prefab refresh preserves pending crossings and queued target identity`,
   which asserts `receiver.count == 268`.
2. Probe: `rfc794_refresh_accounting_probe.zig`, wired by `build.zig.patch` as
   `zig build test-rfc794-probe`. It is not production code and is not part of
   `zig build test`. The build runner reports the step as failed only because
   the probe prints to stderr. Running the built test binary directly prints
   `All 2 tests passed.` That output is in `probe.log`.

Reproduce:

```sh
mkdir rfc794 && cd rfc794
git -C <engine-clone> worktree add --detach "$PWD/labelle-engine" be0991e
git -C <core-clone>   worktree add --detach "$PWD/labelle-core"   85b5546
cd labelle-engine
git apply ../../<this-dir>/build.zig.patch
cp <this-dir>/rfc794_refresh_accounting_probe.zig animation/test/
zig build test-rfc794-probe            # 0.16.0
"$(ls -t .zig-cache/o/*/test | head -1)"   # prints the PROBE lines
```

## Findings

The probe uses the shipped test's fixture: a 3-frame loop with markers on
frames 0 and 1, 4 fps, spawned from a prefab, with a zero-delta tick on the
spawn frame followed by `tick(100)`.

| Measurement | Value | Meaning |
| --- | --- | --- |
| Entered frames offered by `tick(100)` | 400 | 267 marker cues + 133 `engine__anim_loop` events |
| Handed off to `event_buffer` in that update | 64 | the per-update handoff budget |
| Retained in the cursor afterwards | **336** occurrences | 400 − 64, markers **and** loop events |
| Old-playback marker cues after a full drain | 268 | 267 backlog + the spawn-frame `start` cue: all of them |
| Loop events after a full drain | 133 | all of them |
| Drain-then-remove (emulates parked removal) | 268 markers, 133 loops | nothing lost |
| Drain-then-replace, 10-update tail | 268 old + 8 new | the new-playback count depends on the window |
| Today's removal | 0 backlog markers, **21 loop events** | 43 queued markers fail liveness, the cursor's 336 are destroyed, and the queued loop events still reach hooks |
| Today's blocked replacement | refresh never applied, old clip keeps playing | delivered count depends on the window |
| `MarkerCursor` through core `serde` mid-backlog | round-trips | `steps=334`, `sequence=65`, `entering`, `loop_pending`; `remainder_seconds` printed with 6 decimals |

Conclusion: the POC's "336 pending crossings" against "268/304 cues delivered"
is consistent with valid accounting. 336 counts every retained occurrence kind,
while the delivered figures count only `engine__anim_marker` receipts. 268 is
full delivery of the old playback's markers. 304 is consistent with 268 plus
new-playback markers in the POC's window, but that window is unknown, so 304
(and today's 285) stays *reported*. None of these figures shows a lost marker
cue. The 21 loop events delivered after removal are a newly demonstrated
stale-lifecycle delivery (RFC decision 9).

## Code facts checked by reading (be0991e unless noted)

- `TextureManager.invalidateAtlasBinding` (`src/atlas.zig:489-496`) bumps
  `version` when it re-arms an atlas. It returns early without a bump for an
  unknown atlas, an atlas with no retained image, or one already pending.
- `isAnimationMarkerTargetAlive` (`src/game/animation_runtime_mixin.zig:56-61`)
  compares `target_id` only, never `playback_id`. `deliver`
  (`src/game/events_mixin.zig:71-76`) applies it to `engine__anim_marker` only.
- `bindSpriteAnimation` keeps a nonzero authored `marker_target_id` (`:94`).
  Script `componentSetImpl` (`src/script_contract.zig:1517-1541`) bypasses
  binding. `drainEvents` (`:533-540`) forwards subscribed events with no
  liveness check. `componentRemoveImpl` (`:1790-1797`) removes unconditionally.
- labelle-core v2.2.0 `serde.writeComponent` compile-errors on pointers and
  slices (`src/serde.zig:64`). The engine has no pre-save hook.
- Flying Platform `main` `dab1b10f` uses `setSpriteAnimationsPaused`
  (`scripts/playing/97_pause_menu.zig:273`) and reads `sprite_animations_paused`
  (`packs/sky/scripts/playing/38_ceiling_lighting.zig:346`). The POC's "no
  non-test users" holds only within the engine repository.
