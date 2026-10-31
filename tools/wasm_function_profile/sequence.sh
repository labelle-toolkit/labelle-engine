#!/bin/bash
# Alternating base/after samples for labelle-engine#922 (as run on the
# Windows measurement machine; paths and revisions are that setup's:
# `labelle-engine-922-measure` is engine v4.2.0-rc.2 (Flying Platform's
# pin) + #921 (`wp2b-measure-base`) and + #922 (9a13107); fp-922 is a
# Flying Platform clone whose project.labelle pins
# `.engine_version = "local:../labelle-engine-922-measure"`. Never commit
# that pin.) Each variant:
# point the measurement engine + FP's vendored debug plugin at the variant,
# `labelle generate`, then profile.sh (which takes the heavy-build lock).
set -u
S=$(cd "$(dirname "$0")" && pwd)
E=D:/prj/labelle-toolkit/epic-528
FP=$E/fp-922
export LABELLE_ZIG=C:/Users/User/.zvm/0.16.0/zig.exe ZIG_LOCAL_CACHE_DIR=C:/Users/User/.labelle/zig-local-cache ZIG_GLOBAL_CACHE_DIR=C:/Users/User/.labelle/zig-global-cache
variant() { # name engine_rev debug_root_source
  echo "=== $1 $(date +%T)"
  git -C $E/labelle-engine-922-measure checkout -q --detach "$2" || exit 1
  cp "$3" $FP/plugins/debug/src/root.zig
  (cd $FP && labelle generate --platform=wasm --optimize=ReleaseSafe > $S/results/$1-generate.log 2>&1) || { echo generate failed; exit 1; }
  rm -rf $S/results/$1
  $S/profile.sh "$1" $FP || exit 1
}
git -C $E/labelle-assembler-922 show 5ce90db:plugins/debug/src/root.zig > $S/debug-root-base.zig
cp $E/labelle-assembler-922/plugins/debug/src/root.zig $S/debug-root-after.zig
for v in ${VARIANTS:-base2 after2}; do
  case $v in
    base*) variant $v wp2b-measure-base $S/debug-root-base.zig ;;
    after*) variant $v 9a13107 $S/debug-root-after.zig ;;
  esac
done
echo "=== sequence done $(date +%T)"
