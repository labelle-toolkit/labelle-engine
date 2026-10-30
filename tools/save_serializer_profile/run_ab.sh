#!/usr/bin/env bash
#
# A/B driver for measure.py (#921): baseline vs outlined save.zig, two
# interleaved runs each, against a game's generated WASM build.
#
#   BASELINE_SAVE=<old save.zig> OUTLINED_SAVE=<new save.zig> \
#   BUILD_DIR=<game>/.labelle/bgfx_wasm LLVM_NM=<emsdk>/upstream/bin/llvm-nm \
#   OUT=<dir> PYTHON=<python with psutil> tools/save_serializer_profile/run_ab.sh
#
# The caller's environment must already carry what the generated build
# needs (LABELLE_ZIG, EMSDK, ZIG_LOCAL_CACHE_DIR / ZIG_GLOBAL_CACHE_DIR if
# the CLI normally sets them).
#
# Shared-machine etiquette: each run takes HEAVY_LOCK (a directory, mkdir is
# atomic), waits until at least the given GiB of RAM is available, releases
# the lock right after the run and backs off 90 s so other jobs get a turn.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LOCK=${HEAVY_LOCK:-}
PY=${PYTHON:-python}
ZIG=${LABELLE_ZIG:-zig}

available_gib() { "$PY" -c 'import psutil; print(psutil.virtual_memory().available // 2**30)' 2>/dev/null || echo 0; }
take_lock() {
    [ -z "$LOCK" ] && return
    until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
    echo "owner=save-serializer-ab pid=$$ since=$(date -Iseconds)" > "$LOCK/owner"
}
drop_lock() { [ -z "$LOCK" ] && return; rm -f "$LOCK/owner"; rmdir "$LOCK"; }

run() { # name save.zig min_available_gib
    while true; do
        take_lock
        [ "$(available_gib | tr -d '\r')" -ge "$3" ] && break
        drop_lock; sleep 90
    done
    "$PY" "$HERE/measure.py" "$1" --build-dir "$BUILD_DIR" --save-zig "$2" \
        --llvm-nm "$LLVM_NM" --out "$OUT" --zig "$ZIG" --jobs 2
    echo "$1 exit=$?"
    drop_lock
    sleep 90
}

run baseline-1 "$BASELINE_SAVE" 10
run outlined-1 "$OUTLINED_SAVE" 7
run baseline-2 "$BASELINE_SAVE" 10
run outlined-2 "$OUTLINED_SAVE" 7
