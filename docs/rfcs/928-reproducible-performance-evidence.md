# RFC 928: Reproducible performance evidence convention

- **Issue:** labelle-engine#928
- **Status:** Draft. Documentation-only proposal. No code, CI or runtime change.
- **Scope:** How performance-investigation evidence is recorded in this
  repository, so that another contributor can reproduce it.

## 1. Problem

Performance investigations in labelle-engine produce numbers such as
compile time, peak memory, code size and per-tick cost. Those numbers
drive decisions. A reviewer can only trust or re-check a number if they
know exactly how it was produced. Today each investigation records a
different subset of that information, and some leave out the parts that
let someone on another machine reproduce the result.

## 2. What the code shows today (existing evidence)

All of the following was found by inspecting the pinned checkout. None of
it is a proposal.

| Location | What it records | What it leaves out |
|---|---|---|
| `tools/hook_trace_cost.sh` (#858) | Header comment lists the requirements (`zig 0.16.0`, git, `size`, `nm`, python3, perl, macOS/Mach-O). Takes `BASE_REF` as an argument. Pins `-O ReleaseFast`. Uses separate `--cache-dir` / `--global-cache-dir` folders. Explicitly warms the global cache, then interleaves the runs. Explains why SHA-256 is not a stable metric. | Prints results to stdout only, with no saved artifact. Does not record peak memory. |
| `HOOK-TRACING.md` §"On"/"Off" | Results table with a context line: "macOS arm64, Zig 0.16.0, `-OReleaseFast -fstrip`, engine v2.18.0 vs `origin/main` 6fb3429". States "warm global cache". Records a correction: an earlier revision measured in Debug by mistake. | No CPU model, RAM or OS version. No run count beyond "interleaved". |
| `tools/wasm_function_profile/` (#922) | `profile.sh` header describes each step and the shared-machine rules (heavy lock, at least 10 GB of free RAM, `-j2`, 90 s back-off). Each run's results are committed under `results/<variant>/*.json`, with `command`, `cwd`, `wall_seconds` and `tree_peak_private_bytes`. `results/summary.md` aggregates them. | The script hardcodes Windows paths specific to one developer (`C:/Users/User/...`, `D:/prj/...`). The JSON does not record the engine revision, the game (FP) revision, the hardware/OS or the cache state. |
| `tools/save_serializer_profile/` (#921) | `run_ab.sh` documents its environment variables and interleaves A/B runs (2 runs each). `results/*-result.json` holds `command`, wall/CPU seconds and peak private/working-set bytes. | Same gaps: no revisions, no host description, no cache state. The `command` field holds an absolute zig path on one machine. |
| `build.zig` `zig build bench` / `test/script_contract_bench.zig` (#783) | Forces ReleaseFast for the whole module graph. The doc comment explains the workload (2000 entities, Position+Velocity) and the backend caveat (MockEcs is slower than the rig's sparse set). | No convention for where its output goes or what metadata goes with it. |
| `.github/workflows/` | `ci.yml`, `mobile-build.yml`. | No benchmark job. This RFC does not propose adding one. |

**What this adds up to:** the repository already has good habits, used
unevenly. These include pinned optimisation modes, an explicit base ref,
separate caches, cache warm-up, interleaved A/B runs, committed per-run
JSON and documented corrections. No written convention exists. In
particular, no result artifact in the tree records the engine git
revision or the host hardware/OS next to the measurement. The only
revision/host statement found is the prose line in `HOOK-TRACING.md`.

## 3. Proposed design

Contributors add one short **evidence block** to any committed
performance claim. That covers a PR description, an RFC or design doc, or
a `results/` folder under `tools/`. The convention is documentation only.
It needs no tooling, and existing artifacts are not rewritten.

### 3.1 Required fields

| Field | Content | Why it matters |
|---|---|---|
| `engine_rev` | Full git SHA of labelle-engine, plus `dirty` if there are uncommitted changes. For an A/B, give both the base and head SHAs. | Pins the code being measured. |
| `deps` | Revisions or versions of any other repos involved, such as labelle-core or the game under test (e.g. the Flying Platform SHA). Also the `build.zig.zon` hashes if they differ from the engine rev's lockfile. | WASM/game investigations measure more than this repo. |
| `toolchain` | `zig version` output, plus any other compilers or linkers used (e.g. emsdk version). | Results differ between Zig releases. |
| `build` | Optimisation mode (`-Doptimize=` / `-O`), target triple / `-mcpu`, strip flag, `-j` value. | The #858 Debug-vs-ReleaseFast correction shows how much this matters. |
| `host` | OS + version, CPU model, core count, RAM. Note whether the machine was shared or busy. | Context for absolute timings and for memory limits. |
| `commands` | The exact commands, copy-pasteable, with no paths specific to one user. Use variables (`$ZIG`, `$FP_CHECKOUT`) for anything local. | Lets someone else re-run it. |
| `workload` | What is being measured: test file, scene or game, entity count, edit probe. | Lets readers compare like with like. |
| `cache` | `cold` (empty local and global cache dirs, as given) or `warm` (and how it was warmed). | Cold vs warm timings differ by large factors. |
| `runs` | Number of runs, whether A/B runs were interleaved, and how runs were combined (all values, min–max, or median). Never a single number with no run count. | Shows how much the numbers vary. |
| `metrics` | Elapsed wall time. Peak memory, with the tool and definition used (e.g. `/usr/bin/time -v` max RSS, or psutil peak private bytes). Any size or throughput metric, with units. | Peak memory definitions differ between OSes. |
| `artifacts` | Where the raw outputs live (see 3.2). | Lets a reviewer check the summary against the raw data. |

Optional: `notes`, for known caveats such as "MockEcs overestimates" or
"hashes are not byte-reproducible on macOS; sizes are used instead".

### 3.2 Where evidence lives

These follow the existing layout. No new top-level directories are added.

- **Scripts** stay at `tools/<investigation>/` (as today), or in
  `tools/<name>.sh` for a single script.
- **Raw results** go in `tools/<investigation>/results/<run-or-variant>/`
  (as today). Add a small `results/ENVIRONMENT.md` (or `env.json`)
  holding the evidence block for that set of runs.
- **Conclusions** go in the RFC/doc or PR that makes the claim. Each
  results table is followed by its evidence block, or a link to the
  `ENVIRONMENT.md`.
- **Large artifacts** (binaries, multi-MB time reports) are not
  committed. Record the command that regenerates them and, where useful,
  their size and SHA-256.

### 3.3 Capturing the metadata

No helper script is proposed. These existing commands are enough:

```sh
git rev-parse HEAD; git status --porcelain | head -1   # engine_rev / dirty
zig version                                            # toolchain
uname -a                                               # host (OS/kernel)
# CPU/RAM: Linux `lscpu`, `free -g`; macOS `sysctl -n machdep.cpu.brand_string hw.memsize`;
# Windows `Get-CimInstance Win32_Processor, Win32_OperatingSystem`
/usr/bin/time -v <cmd>    # Linux: elapsed + "Maximum resident set size"
/usr/bin/time -l <cmd>    # macOS: elapsed + "maximum resident set size"
```

Investigations that already sample memory with psutil (#921, #922) keep
doing so. They only need to say which psutil field they report.

### 3.4 Example evidence block (ILLUSTRATIVE ONLY)

> **Illustrative template.** Every `<…>` is a placeholder. None of this is
> a real measurement.

```markdown
#### Evidence
- engine_rev: base `<sha>` → head `<sha>` (clean)
- deps: labelle-core `<sha|version>`; game `<repo>@<sha>` (if any)
- toolchain: zig `<zig version output>`; `<other tool + version>`
- build: `-Doptimize=<mode>`, target `<triple>`, `<strip flag>`, `-j<N>`
- host: `<OS + version>`, `<CPU model>`, `<cores>` cores, `<RAM>` GiB, `<idle|shared>`
- workload: `<test file / scene / entity count / edit probe>`
- cache: `<cold: fresh --cache-dir and --global-cache-dir | warm: <how>>`
- runs: `<N>` per variant, `<interleaved|sequential>`, reported as `<all|min–max|median>`
- commands:
  ```sh
  <exact command 1>
  <exact command 2>
  ```
- metrics: wall `<s>`; peak memory `<value>` via `<tool + field>`; `<other metric + unit>`
- artifacts: `tools/<investigation>/results/<variant>/` (regenerate: `<command>`)
- notes: `<caveats>`
```

## 4. Alternatives considered

1. **Do nothing and rely on reviewers asking.** No cost, but the gaps
   listed in §2 already show up in committed artifacts, and reviewers
   cannot re-check numbers after the fact. Rejected.
2. **A shared capture script (e.g. `tools/perf_env.sh`) that writes
   `env.json`.** Useful later, but it is code to maintain across three OS
   families. The issue asks for a lightweight convention. Deferred:
   revisit if contributors keep missing fields.
3. **CI benchmark job / hosted benchmark service.** The issue rules this
   out. Shared CI runners are also too noisy for absolute timings.
   Rejected for this RFC.
4. **Require a machine-readable schema (JSON Schema) for all results.**
   Too heavy for one-off investigations, and existing results use
   different shapes. A Markdown block is enough for humans, and nothing
   prevents a JSON form. Rejected as a requirement.
5. **Retrofit existing artifacts (#858, #921, #922).** Missing revisions
   or host details can't be recovered reliably after the fact, and
   rewriting them risks fabricating data. Rejected. Existing evidence
   stays as it is. Future runs follow the convention.

## 5. Acceptance criteria (for this RFC)

- [ ] Exactly one new file: `docs/rfcs/928-reproducible-performance-evidence.md`.
      No other file changes.
- [ ] Describes the problem, existing practice (with file references), the
      proposed convention, alternatives, risks and the validation plan.
- [ ] Covers every metadata item the issue lists: revision, toolchain,
      build mode/target, hardware/OS, exact commands, workload,
      cold/warm cache, elapsed time, peak memory, artifact location.
- [ ] Includes an example clearly marked illustrative, with placeholders
      only and no fabricated numbers.
- [ ] Explains how a reviewer checks completeness and reproduces a result
      (§7).
- [ ] Proposes no CI service, runtime change or implementation work.

Adoption criteria, if the RFC is accepted later. These are not part of
this change:

- The next performance PR includes an evidence block covering every
  required field in §3.1.
- Its commands contain no paths specific to one user.

## 6. Risks

- **Friction / non-adoption.** Contributors may skip the block. This is
  mitigated by keeping it to about 11 one-line fields and making
  reviewers responsible for checking it (§7), rather than tooling.
- **False sense of reproducibility.** Even with full metadata, absolute
  timings on a different host will differ. The convention should be
  read as "you can reproduce the comparison", not "you will get the same
  number". A/B deltas measured on the same host are the comparable
  quantity.
- **Leaking local details.** Recording host details and commands could
  expose usernames, internal paths or machine names (as the hardcoded
  `C:/Users/User/...` paths in `tools/wasm_function_profile/profile.sh`
  show). The convention requires variables instead of user-specific
  paths and asks for nothing beyond hardware/OS class.
- **Inconsistent peak-memory definitions.** RSS, private bytes and
  working set are not interchangeable. The required "tool + field"
  wording reduces confusion but does not make the values comparable
  across OSes.
- **Repository bloat.** Committing raw results could grow the repo. §3.2
  keeps large artifacts out and asks for regeneration commands instead.

## 7. Validation plan (proposed; nothing below has been run)

This RFC is documentation-only. No builds, tests or benchmarks were run
to write it. Every statement about existing practice in §2 comes from
reading the files named there.

**Reviewer completeness check for this RFC:**

1. Confirm the diff adds only this file.
2. For each row of §2, open the cited file and confirm what it records
   and what it leaves out. For example, check that no `results/*.json`
   under `tools/` contains a git SHA or host field, and that
   `HOOK-TRACING.md` contains the quoted context line.
3. Check §3.1 against the metadata list in issue #928.
4. Confirm §3.4 contains placeholders only.

**Reviewer check for a future investigation that adopts the convention:**

1. **Completeness:** every §3.1 field is present and non-empty, or
   explicitly marked `n/a` with a reason. `runs` gives a count. `metrics`
   names the peak-memory tool and field.
2. **Consistency:** the summary table values can be traced to files under
   the stated `artifacts` path.
3. **Reproduction:** on any machine that meets `toolchain` and `host`
   class:
   1. `git checkout <engine_rev>` (and the `deps` revisions).
   2. Match the `cache` condition. For cold runs, point
      `--cache-dir` / `--global-cache-dir` (or `ZIG_LOCAL_CACHE_DIR` /
      `ZIG_GLOBAL_CACHE_DIR`) at empty folders.
   3. Run `commands` verbatim with the same `runs` count and
      interleaving.
   4. Compare the **direction and rough size of A/B deltas**, not
      absolute values.
   5. Report any divergence on the PR with your own evidence block.

**Possible pilot (needs a separate, explicitly scoped task):** re-run one
existing, cheap investigation, such as `zig build bench` or step 4 of
`tools/hook_trace_cost.sh` on an ELF host after the documented
`size -m` → `size -A` swap, and record a full evidence block. Then check
whether a second contributor can reproduce the delta from that block
alone. This RFC does not do the pilot.
