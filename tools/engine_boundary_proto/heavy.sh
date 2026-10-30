#!/bin/bash
# usage: heavy.sh <run_name> <cwd> [zig build args...]
name=$1; cwd=$2; shift 2
S="C:/Users/User/AppData/Local/Temp/claude/D--prj-labelle-toolkit/59b740bb-78d4-4495-adab-2a9403264606/scratchpad"
export LABELLE_ZIG=C:/Users/User/.zvm/0.16.0/zig.exe
export ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-D:/prj/labelle-toolkit/epic-528/zig-local-cache-923}
export ZIG_GLOBAL_CACHE_DIR=C:/Users/User/.labelle/zig-global-cache
export EMSDK=C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0
export EMSDK_PYTHON=$EMSDK/python/3.9.2-nuget_64bit/python.exe
LOCK=D:/prj/labelle-toolkit/epic-528/.heavy-lock
echo "waiting for lock $(date +%T)"
until mkdir $LOCK 2>/dev/null; do sleep 30; done
trap 'rmdir $LOCK; echo "lock released $(date +%T)"' EXIT
echo "lock acquired $(date +%T)"
D:/prj/labelle-toolkit/wasm-investigation-evidence/venv/Scripts/python.exe $S/measure.py $S/results $name "$cwd" -- C:/Users/User/.zvm/0.16.0/zig.exe build -Doptimize=ReleaseSafe -j2 --summary all "$@"
