# RFC 930: Seed convention for engine tests

**Status:** Draft (revision 5). Documentation only. Nothing is implemented, and runtime behaviour does not change.

**Tracking:** labelle-engine#930

## 1. Problem and context

A test that uses randomness is hard to reproduce from a failure report unless
the seed and its source are recorded. Labelle-engine does not write down how
tests pick seeds, how a contributor replays a failing seed, or how the seed
reaches a failure report. Today's tests stay reproducible only because their
authors hard-code seeds. Nothing guides the next test that wants wider input
coverage, such as a sweep over particle configs.

This RFC records what the code does today and proposes a small convention. It
adds no dependency, no CI service, no command change and no runtime change.

## 2. Current state (what the code and toolchain show today)

Sources:

- `grep` over first-party *.zig files in (`animation/`,
  `audio_backend/`, `codegen/`, `contract/`, `examples/`, `jsonc/`, `scene/`,
  `spec/`, `src/`, `test/`, `tools/`, `usage/`) for `std.Random`,
  `DefaultPrng`, `Xoshiro`, `random_seed`, `io.random` and
  `crypto.random`. This excludes vendored `zig-pkg/` and non-Zig files such as
  `codegen/main.zig.template`. Only two files match: `src/particles.zig` and
  `src/storage/files.zig`. A broader `seed` grep was used for §2.2.
- The Zig standard library for the pinned toolchain, Zig 0.16.0
  (`build.zig.zon:5`, `minimum_zig_version = "0.16.0"`). Paths below are
  relative to the Zig installation (`lib/std/…`, `lib/compiler/…`). *Evidence
  note:* they were read from the local installation; line numbers may shift
  in other 0.16.x builds.
- Runtime observations recorded in the review of revision 2, marked
  *observed by review* below. No builds or tests were run for this revision.

### 2.1 Where RNGs are created

| Location | Generator | Seed source | Purpose |
|---|---|---|---|
| `src/particles.zig:161`, `:175-182` (`ParticleSystem.init`) | `std.Random.DefaultPrng` | `EmitterConfig.seed: u64 = 0` (`:121`) | Per-emitter simulation; same seed + same `step` sequence gives identical state (module doc `:20-23`). |
| `src/particles.zig:220` (`reset`) | same | reseeds from `config.seed` | Deterministic replay. |
| `src/particles.zig:402, 420, 439` (`presets`) | config values | literals `0x5_010`, `0x5_9a5`, `0x5_141` | Engine source; "deterministic out of the box". |
| `src/storage/files.zig:89` | `io.random` (OS entropy) | not seedable | Unique staging file names; needs uniqueness, not reproducibility. |

The scoped grep above finds no other RNG and no read of
`std.testing.random_seed`, `io.random` or `std.crypto.random` in any test
directory (`test/`, `animation/`, `scene/`, `jsonc/`, `audio_backend/`,
`spec/`) or in `tools/`. The only example,
`examples/uikit-gpu/main.zig`, uses no randomness. Most other `seed` hits mean
camera seeding (`src/game/camera_mixin.zig:66`), unrelated to RNGs.

### 2.2 How tests choose seeds

- `test/particles_test.zig` hard-codes a seed in every hand-written config
  (e.g. `0xABCDEF` at line 30, `42` at 57, `7` at 87, `0` at 257). Its preset
  loop (`:289-303`) uses `engine.particle_presets`, whose seeds are the
  literals in `src/particles.zig:402, 420, 439`.
- `test/particles_tick_test.zig` hard-codes `1`–`5` (lines 135, 161, 198, 215,
  230). Literals overlap across files, which is harmless: each test builds its
  own `ParticleSystem`.
- `test/editor_api_test.zig:2148-2155` uses `{"seed":42}`, and
  `test/script_contract_test.zig:3518` formats `{"seed":…}`, only as opaque
  JSON payloads, not RNG seeds.
- No file in the search scope reads `std.testing.random_seed`.
- A particle config that omits `.seed` gets the fixed value `0` from
  `EmitterConfig.seed` (`src/particles.zig:121`) and is reproducible.

**How a failing test reports its seed today: it does not.** No test prints a
seed. None of the `std.debug.print` calls in `test/` print a seed; the only
`seed`-plus-print match is the JSON `bufPrint` at
`test/script_contract_test.zig:3518`. Each test's seed is the literal in
its own source (`test/particles_test.zig:30, 57, 87, 257`;
`test/particles_tick_test.zig:135, 161, 198, 215, 230`; presets at
`src/particles.zig:402, 420, 439`). So for a failure, the test name plus that
literal is the whole reproduction record. The `--seed=0x…` in the build
runner's `failed command:` line (§2.3) is the *run* seed, and these tests
ignore it.

So the de-facto practice is **fixed literal seeds**, unwritten, with the
literal in the source as the only seed record.

### 2.3 What the toolchain provides

- `std.testing.random_seed: u32` (`lib/std/testing.zig:9-11`), "deterministic
  randomness in unit tests". The test runner sets it from `--seed=<u32>`
  (`lib/compiler/test_runner.zig:55-57`).
- The standard Zig test runner receives `--cache-dir=…`, `--seed=0x<b.graph.random_seed>`
  and `--listen=-` through `addRunArtifact` (`lib/std/Build/Step/Run.zig:244-251`).
  This covers the `test_files` binaries wired through `addTest` and
  `addRunArtifact` (`build.zig:140,558-572`). The zspec `spec/` runner uses
  `.simple` (`build.zig:844-851`), which skips that wiring
  (`lib/std/Build.zig:986-989`), so its testing seed stays at 0. The
  `test/*_exe.zig` harnesses use `addExecutable`
  (`build.zig:471-484,506-545`) and receive no runner seed either.
- **For standard-runner tests under `zig build test` and `zig test`, the default seed is random per
  invocation.** `Graph.random_seed = 0`
  (`lib/std/Build.zig:128`) is only the build runner's initial value; the
  `zig build` driver (Zig's `src/main.zig`, not shipped in the installation's `lib/`)
  passes `--seed 0x<random u32>` to the build runner, which parses it as a
  `u32` (`lib/compiler/build_runner.zig:270-277`). The help text
  "(default: random)" (`build_runner.zig:1678`) is accurate. *Observed by
  review:* two plain `zig build test` runs gave test seeds `173992823` and
  `3341774029`; `zig build test --seed 0x1234` gave `4660`; two plain
  `zig test t.zig` runs also gave different seeds.
- **A test binary run directly without `--seed=` gets seed 0, not a random
  one.** `random_seed` starts at `0` (`lib/std/testing.zig:11`), and only a
  `--seed=` argument changes it (`lib/compiler/test_runner.zig:55-57`). A
  bare binary run is therefore repeatable but does not explore.
- Consequence: CI's `zig build test --summary all` (`.github/workflows/ci.yml:80`)
  passes no seed, so eligible standard-runner binaries receive a random run seed. Today
  this has no effect because no test reads it (§2.2).
- **Failure output.** Under the default `.verbose` error style
  (`build_runner.zig:116`, `:1724-1729`) the build runner prints
  `failed command: …` (`build_runner.zig:1515-1523`). The command, including
  `--seed=0x…`, is recorded before the child is spawned
  (`Run.zig:1539-1544`), so it appears for panics and crashes too.
- **Test stderr is visible.** For `.zig_test`, stderr is piped
  (`Run.zig:1566-1571`) and attached to the error for a failing test
  (`Run.zig:1966-1972`) and for crashes (`Run.zig:1731-1740`). *Observed by
  review:* a `std.debug.print` from a failing test appeared in `zig build`
  output.
- **The printed command is not directly replayable.** It ends in
  `--listen=-`, which puts the test runner in server mode reading stdin
  (`test_runner.zig:53-54, 70-71`). *Observed by review:* running it as
  printed aborts with `internal test runner failure: EndOfStream`; dropping
  `--listen=-` runs the tests with the given seed.

## 3. Proposed design

The proposal accepts the toolchain's random default (§2.3) rather than
changing commands. Fixed-seed tests are unaffected by it; sweep tests use it
for exploration, and the printed seed is the replay mechanism.

### Rule 1: fixed literal seeds by default

A test that needs randomness uses a literal seed in the test file, as
`test/particles_test.zig` does. It ignores `std.testing.random_seed`, so it
is the same on every run, in CI and locally. This is required for regression
vectors and bit-identical assertions. Literal reuse across tests is fine when
each test owns its generator.

### Rule 2: sweep tests mix in `std.testing.random_seed`

Place sweep tests only in standard-runner binaries wired through `test_files`.
Use Rule 1 in zspec and executable harnesses until they have explicit seed
forwarding. A sweep derives its seed from the run seed and a nonzero,
unique per-test literal declared as `const sweep_seed_<test>: u64 = …`.
Use canonical hexadecimal without digit separators so duplicates are easy to
compare. Avoid OS entropy and clocks.

```
effective_seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ <per-test literal>
```

Two sweep tests with the same literal share a stream on every run. A reviewer
treats that as a defect (§6 step 4 checks it by grep). Consequences:

- **Default run (local and CI).** Each eligible invocation picks a random
  `u32`, so sweep tests explore a stream that can vary between runs. A sweep test
  must therefore pass for *every* seed; a seed-dependent failure is a real
  bug, not flakiness to retry away.
- **Reproducing.** Take the `u32` from the failure report (Rule 3) and run
  `zig build test --seed 0x<u32>` (space-separated, build-runner syntax).
  The replay value is always the 32-bit `random_seed`, never the 64-bit
  effective seed, which `--seed` rejects.
- **Running a binary by hand.** Copy the `failed command:` line, **remove
  `--listen=-`** (and optionally `--cache-dir=…`), and keep
  `--seed=0x<u32>` (`=` syntax, test-runner form). Without removing
  `--listen=-` the runner waits on stdin and aborts (§2.3). Keep the
  `--seed=` argument: a binary run without it uses seed 0 (§2.3), not the
  failing seed and not a fresh random one.
- **Pinning locally.** `zig build test --seed 0` gives a repeatable run
  while debugging.

### Rule 3: the seed is visible on failure

- **Error-return failures** (`try`, `testing.expect*`): put an `errdefer`
  after computing the seed that prints the `u32` and the
  `zig build test --seed 0x…` command. Its stderr reaches the build output
  (§2.3).
- **Build-runner fallback.** Panics, crashes, leak checks and logged-error
  failures can bypass the test's `errdefer` (`Run.zig:1970-1978`). For any
  failed standard-runner step with a recorded command, the build runner's
  `failed command: … --seed=0x<u32> --listen=-` line carries the seed under
  the default and CI error style; replay with `zig build test --seed 0x<u32>`
  or the edited command from Rule 2. Under `--error-style minimal` that line
  is absent, so a contributor using it must pass and note `--seed` explicitly.
- **Rule 1 (fixed-literal) tests need no printing.** This matches today
  (§2.2): their seed is the literal in the test source, which together with
  the test name is the reproduction record. Rerunning the named test
  reproduces the failure for any `--seed`, so the run seed in
  `failed command:` does not matter for them. A test that builds configs from
  a table or presets (as at `test/particles_test.zig:289-303`) should include
  the case index or name in its failure message so the literal can be found.

A shared helper (`test/support/seed.zig`) is deferred until two tests need it.
If added, it is imported by relative path and **not** listed in `test_files`
(`build.zig:140`), which lists test binaries (`CLAUDE.md` convention 1).

### Rule 4: examples

No example uses randomness today (§2.1). A future example that needs it
hard-codes a visible literal seed (Rule 1). That answers the issue's three
questions for examples:

- **Default seed:** the literal in the example source.
- **Override:** edit the literal. No flag is needed, because the example runs
  the same way every time.
- **Reporting:** none needed. The seed is visible in source, just as for
  Rule 1 tests.

A runtime seed flag for an example (argv parsing lives in generated mains, not
the engine library, per `CLAUDE.md`) would be new behaviour and is out of
scope.

### Illustrative example (NOT existing code; illustration only)

```zig
// ILLUSTRATIVE ONLY: not present in the repository.
test "particle pool never exceeds max_particles under random configs" {
    const sweep_seed_particle_pool: u64 = 0x93001; // unique among sweep tests
    const seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ sweep_seed_particle_pool;
    // Error returns only; other failures can rely on the `failed command:` line.
    errdefer std.debug.print(
        "sweep seed 0x{x} (reproduce: zig build test --seed 0x{x})\n",
        .{ std.testing.random_seed, std.testing.random_seed },
    );

    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..32) |_| {
        const cfg: engine.EmitterConfig = .{
            .rate = r.float(f32) * 1000,
            .lifetime = 0.1 + r.float(f32),
            .max_particles = 1 + r.uintLessThan(u32, 256),
            .seed = r.int(u64),
        };
        var s = try engine.ParticleSystem.init(testing.allocator, cfg);
        defer s.deinit(testing.allocator);
        s.step(1.0 / 60.0);
        try testing.expect(s.liveCount() <= cfg.max_particles);
    }
}
```

Under plain `zig build test` this uses `(random_u32 << 32) ^ 0x93001`, a
stream that can vary between runs; under `zig build test --seed 0x1234` it always
uses `(0x1234 << 32) ^ 0x93001`.

### Out of scope

- Gameplay randomness at runtime, including `EmitterConfig.seed` defaults and
  the presets.
- `src/storage/files.zig` staging names (OS entropy is correct there).
- Changing the CI command, adding seed matrices, CI artefacts, or
  `zig build test --fuzz` infrastructure.
- Runtime seed flags for examples (Rule 4); fixed-literal examples need none.
- Changing existing tests; they already follow Rule 1.

## 4. Alternatives considered

1. **Deterministic default: pin `--seed 0` in CI and docs.** Makes every run
   identical, so sweep tests never explore in CI. Rejected for now: it needs
   a CI command change and removes the only free exploration sweep tests get.
   Reasonable to revisit if sweep-test failures in CI prove disruptive.
2. **`LABELLE_TEST_SEED` environment variable.** Duplicates `--seed`, needs
   `build.zig` or `std.process` plumbing. Rejected.
3. **`-Dtest-seed=` build option.** Would decouple test seed from
   build-step shuffling, but needs `build.zig` changes and a new import in
   every test. Rejected as heavier than needed.
4. **Fixed seeds only, sweeps forbidden.** The status quo; leaves no
   sanctioned path, so the next author improvises (e.g. `io.random`).
5. **Custom test runner printing the seed per failure.** Too heavy for 100+
   test binaries; the build runner already prints the seed.

## 5. Risks

- **CI is non-deterministic for sweep tests.** A sweep test can fail in CI on
  a seed no one has tried locally. Replay the printed seed, isolate the
  failing input, and add it as a fixed-literal Rule 1 regression. Keep the
  sweep to explore other inputs.
- **Build ordering.** The same `--seed` also controls build-graph dependency
  traversal (`build_runner.zig:272-277,1678`). Replay with the original seed,
  toolchain and build options, and investigate ordering or isolation if
  changing the seed changes the failure.
- **Bad replay instructions.** Copying `failed command:` verbatim aborts
  (`--listen=-`); mixing `--seed 0x…` (build) and `--seed=0x…` (runner)
  syntax fails to parse. Rule 2 spells out both.
- **`errdefer` gaps.** Some failures bypass it (Rule 3); replay relies on `failed command:`,
  absent under `--error-style minimal`.
- **Literal collisions.** Duplicate sweep literals silently share streams;
  check named literals during review using §6.
- **`u32` width.** Mixing adds no entropy; only 2³² streams per test.
- **Toolchain drift.** The random default lives in the Zig driver, outside
  `lib/`; a Zig upgrade beyond 0.16.0 should re-check §2.3.

## 6. Validation plan (proposed; not run in this column)

Existing evidence is §2. Later work should, with `-j1`:

1. **Default varies.** Add a throwaway failing test that prints
   `std.testing.random_seed`; run `zig build test -j1` twice and confirm
   different values; confirm `zig build test -j1 --seed 0x1234` prints `4660`.
2. **Error-return replay.** Make it an `errdefer` sweep test as in §3.
   Confirm the `errdefer` line appears in build output and rerunning with the
   printed seed reproduces the failure.
3. **Panic replay.** Switch to `@panic`; confirm no `errdefer` line, a
   `failed command:` line with `--seed=0x…`, that the verbatim command aborts
   with `EndOfStream`, and that removing `--listen=-` (or using
   `zig build test --seed 0x…`) replays it. Keep the throwaway test for step 6.
4. **Literal uniqueness.** Run `rg -n 'const sweep_seed_' --glob '*.zig' test`
   (include other source directories if they acquire eligible `test_files`).
   Check that each value is nonzero, unique, and in a standard-runner test.
5. **Rule 1 independence.** Existing tests pass under `--seed 0` and
   `--seed 0x1234`, which confirms that a fixed-literal failure is reproduced
   from its source literal regardless of run seed.
6. **Bare binary default.** Run a built test binary without `--seed=` or
   `--listen=-` and restore the seed print from step 1 and confirm it prints `0`. Remove it afterward.
7. **Helper wiring.** If `test/support/seed.zig` is added, confirm it is not
   in `test_files` and gets no run step.
8. **Multi-seed sweep.** Run the relevant standard-runner target with 32
   explicit seeds (0 through 31) and record any failure. Replay a failure
   and promote the smallest failing case to a Rule 1 regression. This
   sample validates the workflow and is not exhaustive.
9. **Re-grep** every Zig source directory listed in §2 for `io.random`,
   `std.crypto.random`, `DefaultPrng`, `random_seed` or time-based seeds.

## 7. Acceptance criteria for this RFC

- [ ] The PR adds exactly one file, `docs/rfcs/930-deterministic-test-seed-convention.md`.
- [ ] Current state cites file/line evidence and lists the grep scope and exclusions.
      It states that the default `zig build test` / CI seed is random per
      invocation for standard-runner tests, that a bare standard-runner binary defaults to 0, and that no written
      convention exists today.
- [ ] Current state says how a failing test reports its seed today: it does
      not print one, and the literal in the source is the reproduction
      record. Rule 3 keeps that for fixed-seed tests.
- [ ] Rules cover the default seed (Rule 1, plus random run seed for sweeps),
      override via `zig build test --seed 0x<u32>` with the `--listen=-`
      caveat (Rule 2), and failure visibility for error returns and runner failures
      (Rule 3).
- [ ] Sweep tests are scoped to standard-runner binaries and their named literals are nonzero and unique.
- [ ] Examples are addressed for default, override and reporting (Rule 4).
- [ ] The illustrative example is clearly marked as not existing code.
- [ ] Out of scope includes runtime gameplay randomness; no new dependency,
      CI service, command change or runtime change is proposed.
- [ ] Alternatives, risks and a validation plan are included and kept
      separate from existing evidence.
