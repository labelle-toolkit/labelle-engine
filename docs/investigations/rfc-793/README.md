# Reproduce the RFC #793 baseline investigation

These probes document current limitations; a future implementation should
change those observations. They are not permanent correctness expectations.

Requirements: Git, Python 3, Zig 0.16.0 and local clones of labelle-engine and
labelle-core containing the revisions below. The script exports committed
source into a temporary directory and leaves the source checkouts unchanged.
It runs six investigation probes plus four existing suites (30 tests).

```sh
python3 docs/investigations/rfc-793/reproduce.py \
  --engine-repo /path/to/labelle-engine \
  --core-repo /path/to/labelle-core \
  --zig /path/to/zig
```

The [recorded run](probes.log) passed 36/36 tests on native macOS. The
reproduction fixes the source revisions and toolchain; it does not establish
the behavior of unreleased RFC features or reproduce a full game/UI run.

## RFC #794 POC revalidation (November 8)

[`poc-794/`](poc-794/README.md) records what was available for re-checking the
November 7 POC claims at engine `be0991e`: why the six `poc/794-*` branches
cannot be re-run, plus the refresh/removal accounting probe, its build patch,
the exact commands and the full output.
