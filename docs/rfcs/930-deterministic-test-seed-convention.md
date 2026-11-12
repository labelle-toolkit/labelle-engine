# RFC 930: Seed convention for engine tests

**Status:** Draft (revision 3). Documentation only. Nothing is implemented, and runtime behaviour does not change.

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

Sources: `grep` over `src/`, `test/`, `animation/`, `examples/` and `tools/`
for `Random`, `DefaultPrng`, `Xoshiro`, `random`, `random_seed` and `seed`;
the Zig 0.16.0 library at `/opt/zig/lib` (`build.zig.zon`:
`minimum_zig_version = "0.16.0"`); and the runtime observations recorded in
the review of revision 2 (marked *observed by review* below). I ran no builds
or tests for this revision.

### 2.1 Where RNGs are created

| Location | Generator | Seed source | Purpose |
|---|---|---|---|
| `src/particles.zig:161`, `:175-182` (`ParticleSystem.init`) | `std.Random.DefaultPrng` | `EmitterConfig.seed: u64 = 0` (`:121`) | Per-emitter simulation; same seed + same `step` sequence gives identical state (module doc `:20-23`). |
| `src/particles.zig:220` (`reset`) | same | reseeds from `config.seed` | Deterministic replay. |
| `src/particles.zig:402, 420, 439` (`presets`) | config values | literals `0x5_010`, `0x5_9a5`, `0x5_141` | Engine source; "deterministic out of the box". |
| `src/storage/files.zig:89` | `io.random` (OS entropy) | not seedable | Unique staging file names; needs uniqueness, not reproducibility. |

No other RNG exists in engine source or `tools/`. The only example,
`examples/uikit-gpu/main.zig`, uses no randomness. Most other `seed` hits mean
camera seeding (`src/game/camera_mixin.zig:66`), unrelated to RNGs.

### 2.2 How tests choose seeds

- `test/particles_test.zig` hard-codes a seed in every config (e.g. `0xABCDEF`
  at line 30, `42` at 57, `7` at 87, `0` at 257).
- `test/particles_tick_test.zig` hard-codes `1`–`5` (lines 135, 161, 198, 215,
  230). Literals overlap across files, which is harmless: each test builds its
  own `ParticleSystem`.
- `test/editor_api_test.zig:2148-2155` uses `{"seed":42}` only as an opaque
  JSON payload.
- No file reads `std.testing.random_seed`.

So the de-facto practice is **fixed literal seeds**, unwritten.

### 2.3 What the toolchain provides

- `std.testing.random_seed: u32` (`lib/std/testing.zig:9-11`), "deterministic
  randomness in unit tests". The test runner sets it from `--seed=<u32>`
  (`lib/compiler/test_runner.zig:55-57`).
- `zig build` passes `--cache-dir=…`, `--seed=0x<b.graph.random_seed>` and
  `--listen=-` to every test run step (`lib/std/Build/Step/Run.zig:244-251`).
  `build.zig:558-572` routes every `test_files` entry (`build.zig:140`)
  through `addTest` + `addRunArtifact`, so every engine test binary gets it.
- **The default seed is random per invocation.** `Graph.random_seed = 0`
  (`lib/std/Build.zig:128`) is only the build runner's initial value; the
  `zig build` driver (Zig's `src/main.zig`, not shipped in `/opt/zig/lib`)
  passes `--seed 0x<random u32>` to the build runner, which parses it as a
  `u32` (`lib/compiler/build_runner.zig:270-277`). The help text
  "(default: random)" (`build_runner.zig:1678`) is accurate. *Observed by
  review:* two plain `zig build test` runs gave test seeds `173992823` and
  `3341774029`; `zig build test --seed 0x1234` gave `4660`; two plain
  `zig test t.zig` runs also gave different seeds.
- Consequence: CI's `zig build test --summary all` (`.github/workflows/ci.yml:80`)
  passes no seed, so every CI run uses a fresh random `random_seed`. Today
  this has no effect because no test reads it.
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

A test meant to cover many inputs must not use `io.random`,
`std.crypto.random` or a clock. It derives its seed from the run seed and a
**per-test literal that is unique among sweep tests**:

```
effective_seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ <per-test literal>
```

Two sweep tests with the same literal share a stream on every run; a reviewer
treats that as a defect (§6 step 4 checks it by grep). Consequences:

- **Default run (local and CI).** Each invocation picks a new random
  `u32`, so sweep tests explore a different stream every run. A sweep test
  must therefore pass for *every* seed; a seed-dependent failure is a real
  bug, not flakiness to retry away.
- **Reproducing.** Take the `u32` from the failure report (Rule 3) and run
  `zig build test --seed 0x<u32>` (space-separated, build-runner syntax).
  The replay value is always the 32-bit `random_seed`, never the 64-bit
  effective seed, which `--seed` rejects.
- **Running a binary by hand.** Copy the `failed command:` line, **remove
  `--listen=-`** (and optionally `--cache-dir=…`), and keep
  `--seed=0x<u32>` (`=` syntax, test-runner form). Without removing
  `--listen=-` the runner waits on stdin and aborts (§2.3).
- **Pinning locally.** `zig build test --seed 0` gives a repeatable run
  while debugging.

### Rule 3: the seed is visible on failure

- **Error-return failures** (`try`, `testing.expect*`): put an `errdefer`
  after computing the seed that prints the `u32` and the
  `zig build test --seed 0x…` command. Its stderr reaches the build output
  (§2.3).
- **Panics and crashes** skip `errdefer`. The build runner's
  `failed command: … --seed=0x<u32> --listen=-` line carries the seed under
  the default and CI error style; replay with `zig build test --seed 0x<u32>`
  or the edited command from Rule 2. Under `--error-style minimal` that line
  is absent, so a contributor using it must pass and note `--seed` explicitly.
- Rule 1 tests need nothing extra.

A shared helper (`test/support/seed.zig`) is deferred until two tests need it.
If added, it is imported by relative path and **not** listed in `test_files`
(`build.zig:140`), which lists test binaries (`CLAUDE.md` convention 1).

### Rule 4: examples

No example uses randomness today. A future example that needs it hard-codes
a visible literal seed (Rule 1). Overriding and printing an example's seed
belongs to that example's own arguments and is out of scope.

### Illustrative example (NOT existing code; illustration only)

```zig
// ILLUSTRATIVE ONLY: not present in the repository.
test "particle pool never exceeds max_particles under random configs" {
    const per_test: u64 = 0x930_01; // unique among sweep tests
    const seed: u64 = (@as(u64, std.testing.random_seed) << 32) ^ per_test;
    // Error returns only; panics rely on the `failed command:` line.
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

Under plain `zig build test` this uses `(random_u32 << 32) ^ 0x930_01`, a
different stream each run; under `zig build test --seed 0x1234` it always
uses `(0x1234 << 32) ^ 0x930_01`.

### Out of scope

- Gameplay randomness at runtime, including `EmitterConfig.seed` defaults and
  the presets.
- `src/storage/files.zig` staging names (OS entropy is correct there).
- Changing the CI command, adding seed matrices, CI artefacts, or
  `zig build test --fuzz` infrastructure.
- Example seed override/reporting (Rule 4).
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
  a seed no one has tried locally. Mitigation: Rule 2's "pass for every
  seed" requirement, and the seed in the failure output makes it replayable.
  Rule 1 tests stay deterministic.
- **Bad replay instructions.** Copying `failed command:` verbatim aborts
  (`--listen=-`); mixing `--seed 0x…` (build) and `--seed=0x…` (runner)
  syntax fails to parse. Rule 2 spells out both.
- **`errdefer` gaps.** Panics skip it; replay relies on `failed command:`,
  absent under `--error-style minimal`.
- **Literal collisions.** Duplicate sweep literals silently share streams;
  caught only by review/grep.
- **`u32` width.** Mixing adds no entropy; only 2³² streams per test.
- **Toolchain drift.** The random default lives in the Zig driver, outside
  `/opt/zig/lib`; a Zig upgrade should re-check §2.3.

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
   `zig build test --seed 0x…`) replays it. Remove the throwaway test.
4. **Literal uniqueness.** Grep sweep tests' per-test literals for
   duplicates.
5. **Rule 1 independence.** Existing tests pass under `--seed 0` and
   `--seed 0x1234`.
6. **Helper wiring.** If `test/support/seed.zig` is added, confirm it is not
   in `test_files` and gets no run step.
7. **Re-grep** for `io.random`, `std.crypto.random` or time-based seeds in
   tests and examples.

## 7. Acceptance criteria for this RFC

- [ ] The PR adds exactly one file, `docs/rfcs/930-deterministic-test-seed-convention.md`.
- [ ] Current state cites file/line evidence, states that the default
      `zig build test` / CI seed is random per invocation, and claims no
      written convention exists today.
- [ ] Rules cover the default seed (Rule 1, plus random run seed for sweeps),
      override via `zig build test --seed 0x<u32>` with the `--listen=-`
      caveat (Rule 2), and failure visibility for error returns and panics
      (Rule 3).
- [ ] Sweep-test literals are required to be unique.
- [ ] Examples are addressed (Rule 4).
- [ ] The illustrative example is clearly marked as not existing code.
- [ ] Out of scope includes runtime gameplay randomness; no new dependency,
      CI service, command change or runtime change is proposed.
- [ ] Alternatives, risks and a validation plan are included and kept
      separate from existing evidence.
