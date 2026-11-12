# RFC 930: Deterministic seed convention for engine tests

**Status:** Draft (revision 2). Documentation only. Nothing is implemented, and runtime behaviour does not change.

**Tracking:** labelle-engine#930

## 1. Problem and context

Tests or examples that use randomness are hard to reproduce from a failure
report unless the seed and where it came from are recorded. Labelle-engine
does not write down how tests should pick seeds, how a contributor replays a
failing seed, or how the seed gets into a failure report. Today the tests stay
reproducible only because their authors hard-code seeds. Nothing guides the
next test that wants wider input coverage, such as a property-style sweep over
a particle config or a randomised ECS add/remove sequence.

This RFC writes down what the code already does and proposes a small
convention for new tests and future examples. It adds no dependencies, no CI
services and no runtime changes.

## 2. Current state (what the code shows today)

I found this with `grep` over `src/`, `test/`, `animation/`, `examples/`,
`spec/`, `scene/`, `jsonc/` and `tools/` for `Random`, `DefaultPrng`,
`Xoshiro`, `.random(`, `random_seed` and `seed`. I also read the Zig 0.16.0
standard library at `/opt/zig/lib`, which is the toolchain pinned by
`build.zig.zon` (`minimum_zig_version = "0.16.0"`).

### 2.1 Where RNGs are created

| Location | Generator | Seed source | Purpose |
|---|---|---|---|
| `src/particles.zig:161` (`prng` field), `src/particles.zig:175-182` (`ParticleSystem.init`, seeding at 178) | `std.Random.DefaultPrng` (Xoshiro256) | `EmitterConfig.seed: u64 = 0` (`src/particles.zig:119-121`) | Per-emitter simulation. The module doc (`src/particles.zig:20-23`) promises the same seed plus the same `step` sequence gives byte-identical particle state. |
| `src/particles.zig:220` (`ParticleSystem.reset`) | same | reseeds from `config.seed` | Replays the run deterministically. |
| `src/particles.zig:383-441` (`presets`; seeds at 402, 420, 439) | n/a (config values) | fixed literals `0x5_010`, `0x5_9a5`, `0x5_141` | Engine source, not an example. The comment (383-385) says the presets are "deterministic out of the box". |
| `src/storage/files.zig:88-89` | `io.random(...)` (OS entropy) | none (not seedable) | Unique staging file names in `.pending/`. This needs uniqueness, not reproducibility. |

I found no other RNG in engine source or the `tools/` scripts. The only
example, `examples/uikit-gpu/main.zig`, uses no randomness: a grep of
`examples/` for `Random`, `DefaultPrng`, `Xoshiro` and `random` returns
nothing. `src/tilemap.zig:21-23` mentions a seed only in passing: games that
generate maps must save their own generator input. The engine draws no random
numbers there. Most other `seed` hits in the source mean *camera seeding*
(`seedCameraFromComponent`, `src/game/camera_mixin.zig:66`), which has
nothing to do with randomness.

### 2.2 How tests choose seeds

- `test/particles_test.zig` sets a hard-coded seed in every config:
  `0xABCDEF` (line 30), `42` (57), `7` (87), `1` (111, 196), `3` (135),
  `9` (153), `2` (167), `5` (179), `4` (216), `6` (237), `0` (257).
- `test/particles_tick_test.zig` hard-codes seeds `1` to `5` (lines 135, 161,
  198, 215, 230). These overlap with literals in `test/particles_test.zig`.
  This is harmless: each test builds its own `ParticleSystem`, so no PRNG
  state is shared between tests.
- `test/editor_api_test.zig:2148-2155` uses `{"seed":42}` only as an opaque
  JSON payload. It is not an RNG.
- No file in this repository reads `std.testing.random_seed`.

So the de-facto practice is **fixed literal seeds**. It is not written down
anywhere.

### 2.3 What the toolchain provides (Zig 0.16.0, verified by reading source)

- `std.testing.random_seed: u32` (`lib/std/testing.zig:9-11`) is documented
  as "deterministic randomness in unit tests". Its default is **`0`**. The
  standard library's own tests use it, for example `lib/std/hash_map.zig:1812`
  and `lib/std/heap/ArenaAllocator.zig:648`.
- The test runner sets it from `--seed=<u32>`
  (`lib/compiler/test_runner.zig:54-57`). Without that argument it stays `0`.
  So `zig test test/foo.zig` with no seed argument runs with `0`.
- `zig build` passes `--seed=0x{x}` to every `addTest` run artifact, along with
  `--listen=-` (`lib/std/Build/Step/Run.zig:244-251`, `enableTestRunnerMode`).
  The value is `b.graph.random_seed`.
- **The default `zig build` seed is `0`, not random.**
  `std.Build.Graph.random_seed` is initialised to `0`
  (`lib/std/Build.zig:128`). The only assignment is the `--seed` argument
  parser (`lib/compiler/build_runner.zig:270-277`), which accepts a `u32`
  and rejects anything wider ("unable to parse seed … as unsigned 32-bit
  integer"). The help text "(default: random)"
  (`build_runner.zig:1678`) is stale for this toolchain.
- Consequence: plain `zig build test` runs every engine test binary with
  `--seed=0x0` on every run. The CI test step
  (`.github/workflows/ci.yml:80`, `zig build test --summary all`) passes no
  `--seed`, so CI also always runs with `0`. No workflow file mentions
  `seed`.
- `--seed` is not test-only. The same value shuffles the traversal order of
  the starting build steps (`build_runner.zig:709-710`). A varying default
  would therefore also change build scheduling.
- **Failure reporting.** When a step fails, the build runner prints
  `failed command: …` if `error_style.verboseContext()` is true
  (`build_runner.zig:1515-1523`). The default error style is `.verbose`
  (`build_runner.zig:116`), and `verboseContext()` is true for `.verbose`
  and `.verbose_clear` (`build_runner.zig:1724-1729`). It can be changed with
  `--error-style` or `ZIG_BUILD_ERROR_STYLE` (`build_runner.zig:131-135,
  250-253`); CI sets neither. The `Run` step records the command line,
  including `--seed=0x…`, *before* it spawns the child
  (`lib/std/Build/Step/Run.zig:1539-1544`). So the seed appears in the
  report for any test-binary failure under the default style, including
  panics and crashes, not just `try`/`expect` failures.

`build.zig:558-573` wires every entry of the `test_files` array
(`build.zig:140`) through `b.addTest` plus `b.addRunArtifact`. Each engine
test binary therefore already receives `--seed=0x0`, but no engine test
reads the value.

**Still unverified.** Whether a test's own `std.debug.print` output reaches
the `zig build` output when the runner talks to the build over `--listen=-`.
See §6.

## 3. Proposed design

Three rules for tests, plus one for examples. Rule 1 is the default and
writes down what the code already does. Rules 2 and 3 apply only when a test
opts into seed variation. Because the toolchain default is `0` (§2.3),
variation is **opt-in per invocation**: a plain run is always the same run.

### Rule 1: fixed literal seeds by default

A test that needs randomness uses a **literal seed in the test file**, as
`test/particles_test.zig` does. This is the default seed. It makes the test
fully reproducible with no flags, and it is the right choice for any
regression vector or bit-identical assertion. Seed `0` is allowed. Reusing a
literal across tests is fine when each test builds its own generator, as the
existing particle tests do (§2.2). Distinct literals are only a preference,
and they matter only if two tests could share generator state.

### Rule 2: sweep tests derive their seed from `std.testing.random_seed`

A test that is meant to cover more inputs than one fixed stream, such as a
sweep or fuzz-like property check, must **not** use `io.random`,
`std.crypto.random` or a clock-based seed. It derives its seed from
`std.testing.random_seed`, mixed with a per-test literal so that sweep tests
do not share a stream:

```
effective_seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ <per-test literal>
```

What this means in practice:

- **Default run.** `zig build test` (and CI) passes `--seed=0x0`, so the
  effective seed is just the per-test literal. A plain run is fully
  reproducible, exactly like Rule 1.
- **Exploring.** `zig build test --seed <u32>` gives every sweep test a
  different stream. A contributor varies the seed deliberately, for example
  when changing the code under test. Fixed-seed (Rule 1) tests ignore it.
- **Reproducing a failure.** Rerun with the same `u32`:
  `zig build test --seed 0x<u32>`. Or rerun the binary from the
  `failed command:` line, which already contains `--seed=0x<u32>`. The replay
  value is always the **32-bit `std.testing.random_seed`**, never the 64-bit
  effective seed: `--seed` rejects values wider than `u32`.
- **Direct `zig test`.** Without a seed argument the value is `0`, which is
  the same as the default build run.

This needs no new flag, environment variable or dependency, because the Zig
build system already threads the value through (§2.3). This RFC does **not**
propose making the default vary between runs. That would need a `build.zig`
or CI change, and it would also reshuffle build-step order (§2.3). See
Alternative 5.

### Rule 3: a sweep test makes its seed visible on failure

- **Error-return failures** (`try`, `testing.expect*`): put an `errdefer`
  right after the seed is computed. It prints the `u32` replay value, the
  per-test literal and the override command.
- **Panics, `unreachable`, failed `std.debug.assert`, out-of-bounds access and
  crashes** skip `errdefer`. For these the convention relies on the
  build runner's `failed command: … --seed=0x<u32>` line. That line is
  recorded before the child is spawned and is printed under the default and
  CI error style (§2.3). Together with the per-test literal in the source,
  that is enough to replay. A contributor using `--error-style minimal` must
  note the seed they passed.
- Fixed-seed tests (Rule 1) need nothing extra, because their seed is already
  in the source.

An optional helper, `test/support/seed.zig`, could hold the mixing and
printing code. It should only be added once two or more tests need it. Until
then, inline code is enough. A helper like this is **imported by relative
path** from the test files that use it (as
`test/hook_trace_root_exe.zig:40-41` imports `test/hook_trace_fixtures/`).
It is **not** added to the `test_files` array in `build.zig:140`. That array
lists test *binaries* (`CLAUDE.md` convention 1), and an entry there would
compile and run the helper as its own test.

### Rule 4: examples

No example uses randomness today (§2.1), so this guidance is prospective. An
example that later needs randomness hard-codes a literal seed, following
Rule 1, and keeps it visible in source or in its config. Varying or
overriding an example's seed, and printing it, belongs to that example's own
argument handling. That is out of scope here, because examples have no test
runner and no `std.testing.random_seed`. `particles.presets`
(`src/particles.zig:383-441`) is engine source, not an example, but it
already follows the same fixed-seed idea.

### Illustrative example (NOT existing code; illustration only)

```zig
// ILLUSTRATIVE ONLY: not present in the repository.
test "particle pool never exceeds max_particles under random configs" {
    const per_test: u64 = 0x930_01;
    const seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ per_test;
    // Covers error-return failures only; panics rely on `failed command:`.
    errdefer std.debug.print(
        "sweep seed: random_seed=0x{x} per_test=0x{x} " ++
            "(reproduce: zig build test --seed 0x{x})\n",
        .{ std.testing.random_seed, per_test, std.testing.random_seed },
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

Under plain `zig build test` this test always uses `seed = 0x930_01`.
Under `zig build test --seed 0x1234` it uses `(0x1234 << 32) ^ 0x930_01`.

### Out of scope

- **Gameplay randomness at runtime.** This covers how games seed their RNGs
  and whether `EmitterConfig.seed` defaults should change. The particle API
  and presets stay as they are.
- `src/storage/files.zig` staging names. They need uniqueness, so OS entropy
  is correct there.
- Making the default `zig build test` seed vary, or adding a CI job or seed
  matrix that passes a nonzero `--seed`.
- Fuzzing infrastructure (`zig build test --fuzz`), or recording seeds in CI
  artefacts.
- Seed override or reporting for examples (Rule 4).
- Changing any existing test. The existing tests use fixed literals, which is
  Rule 1. Their reused literals are acceptable under Rule 1 as revised.

## 4. Alternatives considered

1. **An environment variable such as `LABELLE_TEST_SEED`.** This adds a
   second mechanism next to `--seed`, which Zig already ships. It would also
   need a `build.zig` change or `std.process` access in each test. Rejected
   as redundant.
2. **A `-Dtest-seed=` build option injected through an options module.** This
   would separate the test seed from build-step shuffling, but it needs
   `build.zig` changes and a new import in every test module. It could be
   revisited if §6 shows that `--seed` is not usable.
3. **Fixed seeds only, sweep tests forbidden.** This is simplest, and it is
   effectively the status quo. It leaves randomised coverage with no
   sanctioned path, so the next author improvises, for example with
   `io.random`.
4. **A custom test runner that prints the seed for every failing test.**
   This needs the most work and a custom runner for 100+ test binaries. It is
   too heavy for this scope, and §2.3 shows the build runner already prints
   the seed in `failed command:`.
5. **A varying default seed** (for example, CI passing
   `--seed $RANDOM`-style values, or a `build.zig` default). This would make
   sweep tests explore on every run without a contributor asking. It needs a
   CI or build change, makes CI non-repeatable by default, and also
   reshuffles build-step order (`build_runner.zig:709-710`). Rejected for
   this small RFC. A separate proposal could add one nonzero-seed CI run if
   sweep tests become common.

## 5. Risks

- **Sweep tests never vary in CI.** Because the default and CI seed is `0`
  (§2.3), a sweep test only explores in CI the single stream given by its
  literal. Bugs that need other seeds appear only when someone runs
  `--seed` locally. This is accepted: it keeps CI deterministic. Authors
  should not expect CI to find seed-dependent bugs, and reviewers may ask for
  one manual `--seed` run when a sweep test is added.
- **Intermittent failures when exploring.** A contributor running with a
  nonzero `--seed` may hit a failure unrelated to their change. Rule 3 makes
  it replayable, and the default run stays green and repeatable.
- **`errdefer` coverage.** `errdefer` does not run on panics or crashes.
  Rule 3 relies on `failed command:` for those, and that line is missing
  under `--error-style minimal`/`minimal_clear` or `ZIG_BUILD_ERROR_STYLE`.
- **`--seed` also reorders build steps.** Exploring with `--seed` changes
  step scheduling (`build_runner.zig:709-710`) and the run-step command line.
  This may rerun test steps that would otherwise be cached. It does not
  affect correctness.
- **`u32` width.** `std.testing.random_seed` is 32-bit and `--seed` rejects
  wider values. Rule 2's mixing keeps per-test streams distinct but adds no
  entropy, and the replay value is always the `u32`. Pasting the 64-bit
  effective seed fails to parse.
- **Reporting visibility.** `std.debug.print` output from a failing test must
  reach the `zig build` output when the runner uses `--listen=-`. This is not
  yet verified (§6 step 2).
- **Toolchain drift.** The behaviour cited in §2.3, especially the `0`
  default and the stale help text, is Zig 0.16.0. A Zig upgrade should
  re-check those file references.

## 6. Validation plan (proposed; none of this has been run)

This column is documentation-only, so I ran no builds or tests. All §2
evidence comes from reading source. Later work should:

1. **Assert the default.** Run `zig build test -j1 --summary all` (the CI
   form, `.github/workflows/ci.yml:80`) twice. Confirm from a failing or
   verbose run's command line that the test binaries receive `--seed=0x0`
   both times.
2. **Replay with a nonzero seed.** Add a throwaway sweep test, as in §3, that
   fails for an error return. Run `zig build test -j1 --seed 0x1234`.
   Confirm three things: the `errdefer` line from the test reaches the build
   output (the open `--listen=-` question); `failed command:` shows
   `--seed=0x1234`; and rerunning with the same `--seed` reproduces the
   failure while the default run does not (or reproduces the literal-only
   case). Confirm that `--seed` with a 64-bit value is rejected.
3. **Panic path.** Change the throwaway test to `@panic` and confirm that the
   `errdefer` line is absent but `failed command: … --seed=0x1234` is
   present, under both the default error style and the CI invocation. Then
   remove the test.
4. **Rule 1 independence.** Confirm that existing fixed-seed tests pass
   unchanged under `--seed 0x0` and `--seed 0x1234`.
5. **Helper wiring.** If `test/support/seed.zig` is ever added, confirm that
   it is not in `build.zig`'s `test_files` and that `zig build test` does not
   produce a separate run step for it.
6. **Re-grep.** Re-run the §2 grep and confirm that no test or example uses
   `io.random`, `std.crypto.random` or a time-based seed.

## 7. Acceptance criteria for this RFC

- [ ] The PR adds exactly one file, `docs/rfcs/930-deterministic-test-seed-convention.md`
      (a PR-level check, verified on the diff).
- [ ] The current state cites file and line evidence, states that the
      default `zig build test` / CI seed is `0`, and does not claim that a
      written convention exists today.
- [ ] Rules cover choosing the default seed (Rule 1), overriding it with a
      `u32` `--seed` (Rule 2) and making it visible on failure for both
      error returns and panics (Rule 3).
- [ ] Examples are addressed: no example uses randomness today, and Rule 4
      gives prospective guidance and scopes out example override/reporting.
- [ ] The illustrative example is clearly marked as not existing code.
- [ ] Out-of-scope items include runtime gameplay randomness, and the RFC
      proposes no new dependency, CI service or runtime change.
- [ ] Alternatives, risks and a validation plan are included, kept separate
      from the existing evidence. The plan includes a nonzero-seed replay
      case and a panic case.
