# Named sprite-animation markers

This is the first marker-delivery implementation for engine #794. It extends
shared JSONC clips, keeps legacy numeric `event_frames` on their landed-on path,
and leaves the default engine-driver opt-in unchanged.

```json
{"version":1,"clips":{"walk":{
  "frames_pattern":"walk_{frame:04}.png","from":1,"to":8,
  "markers":[{"name":"footstep","frame":2},{"name":"contact","frame":5}]
}}}
```

Marker frames are zero-based indices in the expanded clip, not filename numbers.
Names must be nonempty and unique within a clip. Different clips may reuse a
name. At most 256 markers are accepted per clip; equal-frame cues keep authored
order. Invalid indices, duplicate names, and unknown fields fail definition load.
Names and frame tables belong to the session's immutable animation library.

## Delivery

Subscribe to the typed `engine__anim_marker` event in a hook. Its payload contains
`entity`, `target_id`, `playback_id`, `sequence`, `definition`, `clip`, `marker`,
`marker_index`, `frame`, and `repetition`. The assembler discovers this engine
event through the existing `Events` declaration and hook scanning.

The normal engine tick queues events; hooks run at the next ordinary event drain,
never while the animation ECS view is live. The engine checks the target token
before native hook delivery. Hooks must recheck `game.isAnimationMarkerTargetAlive`
before acting, especially after another receiver could have destroyed a target.
The token identifies an animation attachment, so removing its component also
invalidates its cues. Token allocation never resets with ECS/world resets. Do
not copy live runtime identity fields onto a different entity.

For gameplay, also compare `playback_id` with the current animation before using
an old attack's cue. A clip selection retains the attachment token but starts a
new playback identity. Queued older cues retain their original identity and
owned strings. `game.selectSpriteAnimation(anim, definition, clip)` validates a
replacement atomically. It returns `PendingAnimationMarkers` if the old cursor
has not drained; retry after advancement resumes. Directly overwriting runtime
cursor fields is not a supported playback-control API.

Occurrences are visited chronologically per player, including every crossed
loop. A new start visits frame zero once; zero-delta updates do not replay it.
Once-mode visits final cues before completion. Ping-pong enters each endpoint
once, then visits frames in reverse order. Negative speed retains its existing
meaning of paused, not reverse. The standalone cursor additionally supports a
reverse initial direction. Across entities, enqueue order is ECS traversal order;
there is no cross-entity timestamp sort or backend-independent total order.

## Budgets and backpressure

Each entity gets at most 256 entered frames and 64 event handoffs per update,
shared between its old backlog and new elapsed time. The allocation-free cursor
retains remaining beats and its position among markers on the current frame.
It advances the occurrence sequence only after a successful `tryEmit`. Failed
enqueues therefore retry without duplicating a successful handoff. Loop and
completion handoffs use the same retry path on marked clips.

When old work cannot drain, the animation clock stalls: **new wall time is not
accepted**. This is explicit backpressure, not an unlimited real-time catch-up
guarantee. The first stalled update logs a warning; recovery re-arms it. A batch
must contain fewer than 2^32 beats; invalid or excessive offered time fails
without mutating the cursor. The standalone `offer`/`pump` API exposes these
errors and separate frame/event budgets to callers. Pausing freezes traversal of
deferred beats, but handoff for a frame already entered may finish while paused.

The normal game event queue remains dynamically allocated. This bounds producer
work and cursor memory, not total memory when an application never drains events.
Successful enqueue is not an acknowledgement of handler execution.

## Scope still outstanding

This does not complete the RFC. Persistence of playback/cursor state and pending
events, restore reconciliation, marker-specific subscriber indexes, the full
trigger command boundary, default driving, and scaled/unscaled clock migration
are separate stages. SpriteAnimation remains transient on save/load, and scene
reset retains the existing pending-scene-event discard contract. Do not use this
stage to promise save-continuous or transactional gameplay side effects.

Tests separate pure traversal, failed queue handoff, ordinary hook delivery,
attachment invalidation on ECS reset, pause/backpressure, and clip replacement.
Run `zig build test` inside `animation/`, and `zig build test-animation` at the
engine root. The Flying Platform probe exercises the generated loop and a typed
HookContext receiver with one running and one paused propeller.
