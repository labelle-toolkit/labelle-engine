# Position revisions for prepared queries

`Game.trackPositionRevision(entity)` opts a live entity into world-local
tracking during preparation. It returns an allocation error or a nonzero token;
unknown/dead entities return null. `Game.positionRevision(entity)` is a read-only
lookup: no allocation, parent traversal or registration.

Pair the token with world and entity identity. Tokens from different worlds are
not comparable. A reset clears tracked entities without reusing old tokens;
destruction removes the entity's entry. Tracking consumes memory only for opted-in
entities. No prepared-matching behavior is enabled by this engine change.

Position mutations invalidate the entity and its descendants, even when the
ancestor itself is untracked. Unrelated entities keep their tokens. Covered shared
paths include setPosition/setWorldPosition, position component add/set/field/remove,
setParent/removeParent/detach and keep-transform variants, plus generic Parent
mutations. Generic Parent mutations now use the hierarchy setter so the reverse
Children index stays consistent. Queries compare the published token against the
current token; they do not need to erase the old CMN debugging record.

Raw Children replacement/removal can make the reverse index unreliable. That path
invalidates every tracked token and conservatively keeps doing so on subsequent
position mutations until world reset. Use hierarchy APIs to avoid this fallback.
It is a correctness safeguard, not the expected performance path.

Direct backend writes and mutation through component pointers are not automatically
observable. Migrate them to shared setters before enabling prepared matching. For
unavoidable direct Position writes, call `Game.invalidatePosition(entity)` in the
same mutation operation. Direct Parent/Children writes must migrate to hierarchy
APIs, not merely call this notification: the reverse index must remain consistent.
Low-level loader/deserializer paths also need an explicit audit; a fresh/reset
world has no published tracked entries, but in-place changes to a live tracked
world require invalidation. Known-node publication happens after invalidation.

Freshness does not itself prepare CMNs, publish a graph or schedule a batch. The
pathfinder still needs registration/graph invalidation, node generation checks,
serial snapshot/compute/publication and consumer migration before rollout.

Validation: six lifecycle tests exercise descendant invalidation, generic Parent
mutation, destruction/reset, raw Children fallback, allocation failure and world
isolation. The full engine test suite and Flying Platform's 20 test targets are
also run for this change. No WASM performance result is claimed.

## Aggregate dependency watch

`watchPositionDependency(entity)` enrolls a live entity's position in a single
world-owned dependency group. Ancestor movement, reparenting, destruction and
raw-hierarchy invalidation advance `dependencyRevision()`. Ordinary tracked
workers moving do not advance it unless explicitly enrolled in this group.

`watchComponentDependency(T)` enrolls a component type: shared add/set/remove/
setField and the authored scene writer advance the same group when that type
changes. This catches new graph nodes as well as link/stair edits. Registration
can fail with OOM; consumers must not publish a cache if registration failed.
The token is conservative and scoped to the world, not a component value hash.

Direct ECS or component-pointer writes still require explicit
`invalidateComponentDependency(T)` (and `invalidatePosition(entity)` for spatial
changes). This is not automatic backend instrumentation. Queries only compare
tokens; they never register dependencies or allocate.

## Indexed freshness reads

After tracking, preparation can save `positionRevisionSlot(entity)` alongside
world identity, full entity handle and revision. Matching calls
`positionRevisionAt(entity, slot)` and compares the returned revision with the
saved revision. This uses an array lookup rather than an entity hash lookup;
it does not allocate, inspect ECS components or traverse ancestry.

Slots are recycled on destruction, so the slot alone is not an identity or
freshness token. Reads reject a mismatched entity or empty slot. Re-registering
the same entity, including after reset, receives a new monotonic revision.
Storage follows peak concurrent tracked entities rather than lifetime spawn
count. Tracking allocation failure rolls back registration.

Validation includes slot recycling/reset and every registration allocation
failure. Full engine validation: 1,514 tests passed.
