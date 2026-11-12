# RFC 930: Deterministic seed convention for engine tests

**Status:** Draft. Documentation only. Nothing is implemented, and runtime behaviour does not change.

**Tracking:** labelle-engine#930

## 1. Problem and context

Tests or examples that use randomness are hard to reproduce from a failure
report unless the seed and where it came from are recorded. Labelle-engine
does not write down how tests should pick seeds, how a contributor replays a
failing seed, or how the seed gets into a failure report. Today the tests stay
reproducible only because their authors hard-code seeds. Nothing guides the
next test that wants varied inputs, such as a property-style sweep over a
particle config or a randomised ECS add/remove sequence.

This RFC writes down what the code already does and proposes a small
convention for new tests. It adds no dependencies, no CI services and no
runtime changes.

## 2. Current state (what the code shows today)

I found this with `grep` over `src/`, `test/`, `animation/`, `examples/`,
`spec/`, `scene/`, `jsonc/` and `tools/` for `Random`, `DefaultPrng`,
`Xoshiro`, `.random(`, `random_seed` and `seed`. I also read the Zig 0.16.0
standard library at `/opt/zig/lib`, which is the toolchain pinned by
`build.zig.zon` (`minimum_zig_version = "0.16.0"`).

### 2.1 Where RNGs are created

| Location | Generator | Seed source | Purpose |
|---|---|---|---|
| `src/particles.zig:161,178` (`ParticleSystem.init`) | `std.Random.DefaultPrng` (Xoshiro256) | `EmitterConfig.seed: u64 = 0` (`src/particles.zig:119-121`) | Per-emitter simulation. The module doc (`src/particles.zig:19-23`) promises the same seed plus the same `step` sequence gives bit-identical results. |
| `src/particles.zig:220` (`ParticleSystem.reset`) | same | reseeds from `config.seed` | Replays the run deterministically. |
| `src/particles.zig:384-445` (`presets`) | n/a (config values) | fixed literals `0x5_010`, `0x5_9a5`, `0x5_141` | The comment says the presets are "deterministic out of the box". |
| `src/storage/files.zig:88-89` | `io.random(...)` (OS entropy) | none (not seedable) | Unique staging file names in `.pending/`. This needs uniqueness, not reproducibility. |

I found no other RNG in engine source, the `examples/uikit-gpu` example or the
`tools/` scripts. `src/tilemap.zig:21-24` mentions a seed only in passing:
games that generate maps must save their own generator input. The engine
draws no random numbers there. Most other `seed` hits in the source mean
*camera seeding* (`seedCameraFromComponent`), which has nothing to do with
randomness.

### 2.2 How tests choose seeds

- `test/particles_test.zig` sets a hard-coded seed in every config:
  `0xABCDEF` (line 30), `42` (57), `7` (87), `1` (111, 196), `3` (135),
  `9` (153), `2` (167), `5` (179), `4` (216), `6` (237), `0` (257).
- `test/particles_tick_test.zig` hard-codes seeds `1` to `5` (lines 135, 161,
  198, 215, 230).
- `test/editor_api_test.zig:2148-2155` uses `{"seed":42}` only as an opaque
  JSON payload. It is not an RNG.
- No file in this repository reads `std.testing.random_seed`.

So the de-facto practice is **fixed literal seeds**. It is not written down
anywhere.

### 2.3 What the toolchain already provides (Zig 0.16.0)

- `std.testing.random_seed: u32` (`lib/std/testing.zig:9-11`) is documented
  as "deterministic randomness in unit tests". The standard library's own
  tests use it, for example `lib/std/hash_map.zig:1812` and
  `lib/std/heap/ArenaAllocator.zig:648`.
- The test runner sets it from `--seed=<u32>` (`lib/compiler/test_runner.zig:55-57`).
- `zig build` passes `--seed=0x{x}` to every `addTest` run artifact
  (`lib/std/Build/Step/Run.zig:244-251`, `enableTestRunnerMode`). The value
  comes from `b.graph.random_seed`, which `zig build --seed <int>` sets
  (`lib/compiler/build_runner.zig:270-277`). The help text says
  "(default: random)" (`build_runner.zig:1678`).
- When a step fails, the build runner can print `failed command: …`
  (`build_runner.zig:1515-1521`). For a test step that command line contains
  `--seed=0x…`. The runner prints it only when `error_style.verboseContext()`
  is true.

`build.zig:558-573` wires every `test/*.zig` file through `b.addTest` plus
`b.addRunArtifact`. Each engine test binary therefore already receives
`--seed`, but no engine test reads the value.

**Not verified here.** Two things need confirming before the convention
relies on them: (a) that the default `zig build test` seed really changes
between runs, and (b) that `failed command:` with `--seed` is printed under
the default error style and under the CI invocation
(`.github/workflows/ci.yml:61,80`, `zig build test --summary all`). See the
validation plan (§6).

## 3. Proposed design

Three rules. Rule 1 is the default and writes down what the code already
does. Rules 2 and 3 apply only when a test opts into varied seeds.

### Rule 1: fixed literal seeds by default

A test that needs randomness uses a **literal seed in the test file**, as
`test/particles_test.zig` does. This is the default seed. It makes the test
fully reproducible with no flags, and it is the right choice for any
regression vector or bit-identical assertion. Seed `0` is allowed. Distinct
tests should prefer distinct literals so that two tests do not accidentally
share one stream.

The same rule covers examples: an example that uses randomness hard-codes its
seed, as `particles.presets` does.

### Rule 2: tests that vary the seed derive it from `std.testing.random_seed`

A test that wants a different input on each run, such as a sweep or fuzz-like
coverage, must **not** use `io.random`, `std.crypto.random` or a clock-based
seed. It derives its seed from `std.testing.random_seed`, mixed with a
per-test constant so that tests do not share a stream:

```
seed = (@as(u64, std.testing.random_seed) << 32) ^ <per-test literal>
```

This needs no new flag, environment variable or dependency, because the Zig
build system already threads the value through (§2.3).

**Overriding to reproduce a failure:**

- Through the build: `zig build test --seed 0x<value>`. This replays every
  engine test binary with that seed, and fixed-seed tests are unaffected.
- Directly: rerun the test binary from the `failed command:` line with
  `--seed=0x<value>`.

### Rule 3: a varied-seed test prints its seed on failure

A Rule-2 test prints the effective seed and the override command when it
fails, using an `errdefer` placed right after the seed is computed. The
report then holds the seed even when `failed command:` is not shown (§2.3
caveat). Fixed-seed tests (Rule 1) need nothing extra, because their seed is
already in the source.

An optional helper, `test/support/seed.zig`, imported by relative path, could
hold the mixing and printing code. It should only be added once two or more
tests need it. Until then, inline code is enough. Any new file under `test/`
must follow the existing `build.zig` wiring conventions in `CLAUDE.md`.

### Illustrative example (NOT existing code; illustration only)

```zig
// ILLUSTRATIVE ONLY: not present in the repository.
test "particle pool never exceeds max_particles under random configs" {
    const seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ 0x930_01;
    errdefer std.debug.print(
        "seed=0x{x} (reproduce: zig build test --seed 0x{x})\n",
        .{ seed, std.testing.random_seed },
    );

    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const cfg: engine.EmitterConfig = .{
            .rate = r.float(f32) * 1000,
            .lifetime = 0.1 + r.float(f32),
            .max_particles = 1 + r.uintLessThan(u32, 256),
            .seed = r.int(u64), // emitter seed derived from the test seed
        };
        var s = try engine.ParticleSystem.init(testing.allocator, cfg);
        defer s.deinit(testing.allocator);
        s.step(1.0 / 60.0);
        try testing.expect(s.liveCount() <= cfg.max_particles);
    }
}
```

### Out of scope

- **Gameplay randomness at runtime.** This covers how games seed their RNGs
  and whether `EmitterConfig.seed` defaults should change. The particle API
  and presets stay as they are.
- `src/storage/files.zig` staging names. They need uniqueness, so OS entropy
  is correct there.
- Fuzzing infrastructure (`zig build test --fuzz`), new CI jobs, seed
  matrices, or recording seeds in CI artefacts.
- Changing any existing test. The existing tests already satisfy Rule 1.

## 4. Alternatives considered

1. **An environment variable such as `LABELLE_TEST_SEED`.** This adds a
   second mechanism next to `--seed`, which Zig already ships. It would also
   need a `build.zig` change or `std.process` access in each test. Rejected
   as redundant.
2. **A `-Dtest-seed=` build option injected through an options module.** This
   gives a stable default independent of `zig build`'s seed, but it needs
   `build.zig` changes and a new import in every test module. It could be
   revisited if §6 shows that `--seed` is not usable.
3. **Fixed seeds only, varied seeds forbidden.** This is simplest, and it is
   effectively the status quo. It leaves randomised coverage with no
   sanctioned path, so the next author improvises, for example with
   `io.random`.
4. **A custom test runner that prints the seed for every failing test.**
   This needs the most coverage work and a custom runner for 100+ test
   binaries. It is too heavy for this scope.

## 5. Risks

- **CI flakiness.** A Rule-2 test that fails for some seeds turns a real bug
  into an intermittent red build. Mitigations: Rule 3 makes the failure
  replayable, and Rule 1 stays the default. Reviewers should ask for a
  varied-seed test only where the property must hold for all seeds.
- **Changing default seed and caching.** If `zig build`'s default seed
  varies per run, the `--seed` argument also varies, which may affect
  run-step caching. This needs confirming in §6. It is not a correctness
  risk.
- **`u32` width.** `std.testing.random_seed` is 32-bit. The mixing in Rule 2
  keeps per-test streams distinct but does not add entropy. That is
  acceptable for tests.
- **Reporting visibility.** `std.debug.print` output from a failing test must
  reach the `zig build` output. This is believed to be true, but §6 still
  needs to confirm it.
- **Toolchain drift.** The behaviour cited in §2.3 is Zig 0.16.0. A Zig
  upgrade should re-check those file references.

## 6. Validation plan (proposed; none of this has been run)

This column is documentation-only, so I ran no builds or tests. Later work
should:

1. Run `zig build test -j1 --summary all` twice and check whether the
   `--seed=0x…` values differ (§2.3 caveat a).
2. Add a throwaway failing test that reads `std.testing.random_seed`, as in
   §3, and confirm three things: the build output shows the `errdefer` line
   and/or `failed command: … --seed=0x…`; `zig build test --seed <that value>`
   reproduces the failure; and the same holds under the CI invocation
   (`.github/workflows/ci.yml:80`) (caveat b). Then remove the test.
3. Confirm that existing fixed-seed tests pass unchanged under two different
   `--seed` values. This shows Rule 1 is independent of `--seed`.
4. Re-run the §2 grep and confirm that no test uses `io.random`,
   `std.crypto.random` or a time-based seed.

## 7. Acceptance criteria for this RFC

- [ ] This file is the only change (`docs/rfcs/930-deterministic-test-seed-convention.md`).
- [ ] The current state cites file and line evidence and does not claim that
      a written convention exists today.
- [ ] Rules cover choosing the default seed (Rule 1), overriding it (Rule 2)
      and printing it on failure (Rule 3).
- [ ] The illustrative example is clearly marked as not existing code.
- [ ] Out-of-scope items include runtime gameplay randomness, and the RFC
      proposes no new dependency, CI service or runtime change.
- [ ] Alternatives, risks and a validation plan are included, kept separate
      from the existing evidence.
