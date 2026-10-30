#!/bin/bash
# WP2b (labelle-engine#922) reproducible profile of Flying Platform's
# ReleaseSafe threaded WASM build.
#
# usage: profile.sh <variant> <fp_checkout> [--no-full]
#   1. `zig build profile-game --time-report --webui` : game Zcu only;
#      wall time, peak private memory, LLVM pass time-report, sema/codegen.
#   2. llvm-nm -S on libgame.a : per-function code size, top 30, clusters.
#   3. game-only edit probe (a comptime no-op appended to one generated
#      script), then `zig build profile-game` WITHOUT --time-report : the
#      clean edit-rebuild compile wall time and peak memory.
#   4. `zig build` (full, incl. emcc -O3 link; game lib cached from 3) :
#      link wall time and final .wasm size (skipped with --no-full).
# Shared-machine etiquette: heavy-build lock, >=10 GB free RAM, >=8 GB
# free on C:, 90 s back-off after releasing the lock, -j2.
set -u
variant=$1; fp=$2; full=1; [ "${3:-}" = "--no-full" ] && full=0
S=$(cd "$(dirname "$0")" && pwd)
OUT=$S/results/$variant; mkdir -p "$OUT"
GEN=$fp/.labelle/bgfx_wasm
PY=${PY:-D:/prj/labelle-toolkit/wasm-investigation-evidence/venv/Scripts/python.exe}  # needs psutil + websocket-client
ZIG=${ZIG:-C:/Users/User/.zvm/0.16.0/zig.exe}
export LABELLE_ZIG=$ZIG
export ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-C:/Users/User/.labelle/zig-local-cache}
export ZIG_GLOBAL_CACHE_DIR=C:/Users/User/.labelle/zig-global-cache
export EMSDK=${EMSDK:-C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0}
export EMSDK_PYTHON=$EMSDK/python/3.9.2-nuget_64bit/python.exe
LOCK=D:/prj/labelle-toolkit/epic-528/.heavy-lock
PORT=${WP2B_PORT:-8792}

c_free_gb() { df -BG /c | awk 'NR==2{gsub("G","",$4); print $4}'; }
mem_free_gb() { powershell -NoProfile -c "[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB)" | tr -d '\r'; }

if [ "$(c_free_gb)" -lt 8 ]; then echo "C: has $(c_free_gb) GB free (<8), stopping"; exit 4; fi
# Fairness: back off 90 s after our own last release.
if [ -f "$S/.last-release" ]; then
  since=$(( $(date +%s) - $(cat "$S/.last-release") ))
  [ $since -lt 90 ] && sleep $(( 90 - since ))
fi
while true; do
  echo "waiting for heavy lock $(date +%T)"
  until mkdir $LOCK 2>/dev/null; do sleep 30; done
  echo "owner=wp2b-922 variant=$variant pid=$$ since=$(date -Is)" > $LOCK/owner
  m=$(mem_free_gb)
  if [ "$m" -ge 10 ]; then break; fi
  echo "only ${m} GB RAM free; releasing lock and retrying"
  rm -rf $LOCK; date +%s > "$S/.last-release"; sleep 90
done
trap 'rm -rf $LOCK; date +%s > "$S/.last-release"; echo "lock released $(date +%T)"' EXIT
echo "lock acquired $(date +%T); RAM free $(mem_free_gb) GB; C: free $(c_free_gb) GB"

$PY $S/add_profile_step.py $GEN/build.zig
echo "=== profile-game ($variant) $(date +%T)"
$PY $S/profile_run.py "$OUT" game-report "$GEN" --webui $PORT -- \
  $ZIG build profile-game -Doptimize=ReleaseSafe -j2 --summary all --time-report --webui=127.0.0.1:$PORT || { echo "profile-game failed"; exit 1; }
$PY $S/symbols.py "$GEN/zig-out/profile/libgame.a" "$OUT/game" 30 > "$OUT/symbols-top.txt"; head -45 "$OUT/symbols-top.txt"
echo "=== edit probe + clean compile ($variant) $(date +%T)"
echo "comptime { _ = $(date +%s); } // wp2b labelle-engine#922 game-only edit probe" >> "$GEN/scripts/playing/00_game_time.zig"
$PY $S/profile_run.py "$OUT" game-clean "$GEN" -- $ZIG build profile-game -Doptimize=ReleaseSafe -j2 --summary all || { echo "clean compile failed"; exit 1; }
if [ $full = 1 ]; then
  echo "=== full build ($variant) $(date +%T)"
  $PY $S/profile_run.py "$OUT" full "$GEN" -- $ZIG build -Doptimize=ReleaseSafe -j2 --summary all || { echo "full build failed"; exit 1; }
  find "$GEN/zig-out" -name '*.wasm' -newer "$OUT/game-report.json" -printf '%s %p\n' > "$OUT/wasm-size.txt"; cat "$OUT/wasm-size.txt"
fi
echo "=== done $variant $(date +%T)"
