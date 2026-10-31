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
# the CLI normally sets them). MEASURE overrides the measure.py path and
# AB_MIN_GIB the per-run free-RAM floor (both used by the stub tests).
#
# Shared-machine etiquette: each run takes HEAVY_LOCK (a directory, mkdir is
# atomic), waits until at least the given GiB of RAM is available, releases
# the lock right after the run and backs off 90 s (AB_BACKOFF) so other jobs
# get a turn. An interrupted driver (INT/TERM/HUP) terminates the running
# measurement (`measure.py --abort`: kills its process tree, restores the
# game's files) and releases the lock only if this process took it.
#
# Exits nonzero if any measurement failed (all four runs are still
# attempted), or with 128+signal when interrupted.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LOCK=${HEAVY_LOCK:-}
PY=${PYTHON:-python}
ZIG=${LABELLE_ZIG:-zig}
MEASURE=${MEASURE:-$HERE/measure.py}
BACKOFF=${AB_BACKOFF:-90}

owns_lock=0
child=
failures=0

available_gib() { "$PY" -c 'import psutil; print(psutil.virtual_memory().available // 2**30)' 2>/dev/null || echo 0; }

take_lock() {
    [ -z "$LOCK" ] && return
    until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
    owns_lock=1
    echo "owner=save-serializer-ab pid=$$ since=$(date -Iseconds)" > "$LOCK/owner"
}

drop_lock() {
    [ "$owns_lock" = 1 ] || return 0
    rm -f "$LOCK/owner"
    rmdir "$LOCK"
    owns_lock=0
}

cleanup() {
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        # `measure.py --abort` kills the measurement's whole process tree
        # (the zig compilers) and restores the files it edited. A plain
        # `kill` is not enough: under MSYS/Git Bash it hard-terminates the
        # native python, skipping its cleanup and orphaning the compilers.
        local pid=$child
        [ -r "/proc/$child/winpid" ] && pid=$(cat "/proc/$child/winpid")
        "$PY" "$MEASURE" --abort "$pid" --build-dir "$BUILD_DIR" || kill -KILL "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    fi
    child=
    drop_lock
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run() { # name save.zig min_available_gib
    while true; do
        take_lock
        [ "$(available_gib | tr -d '\r')" -ge "${AB_MIN_GIB:-$3}" ] && break
        drop_lock
        sleep "$BACKOFF"
    done
    # Run in the background and `wait`, so a signal interrupts the wait and
    # reaches the trap now rather than after the multi-minute compile.
    "$PY" "$MEASURE" "$1" --build-dir "$BUILD_DIR" --save-zig "$2" \
        --llvm-nm "$LLVM_NM" --out "$OUT" --zig "$ZIG" --jobs 2 &
    child=$!
    wait "$child"
    local status=$?
    child=
    echo "$1 exit=$status"
    [ "$status" -eq 0 ] || failures=$((failures + 1))
    drop_lock
    sleep "$BACKOFF"
}

run baseline-1 "$BASELINE_SAVE" 10
run outlined-1 "$OUTLINED_SAVE" 7
run baseline-2 "$BASELINE_SAVE" 10
run outlined-2 "$OUTLINED_SAVE" 7

if [ "$failures" -ne 0 ]; then
    echo "$failures of 4 measurements failed" >&2
    exit 1
fi
