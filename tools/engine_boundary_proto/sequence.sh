#!/bin/bash
# Full A/B sequence for labelle-engine#923. Each heavy build takes/releases the lock itself.
set -u
S="C:/Users/User/AppData/Local/Temp/claude/D--prj-labelle-toolkit/59b740bb-78d4-4495-adab-2a9403264606/scratchpad"
L=D:/prj/labelle-toolkit/epic-528/fp-engine-boundary/.labelle
GEN=$L/bgfx_wasm
ENG=D:/prj/labelle-toolkit/epic-528/labelle-engine-boundary
PY=D:/prj/labelle-toolkit/wasm-investigation-evidence/venv/Scripts/python.exe
step() { echo "=== $1 $(date +%T)"; }
stop_if_paused() { if [ -e D:/prj/labelle-toolkit/epic-528/.pause-builds ]; then echo "paused marker present, stopping"; exit 3; fi; }
stop_if_paused; step base-cold;  $S/heavy.sh base-threaded-cold $GEN || exit 1
stop_if_paused; step base-edit1; $S/game_edit.sh; $S/heavy.sh base-threaded-edit1 $GEN || exit 1
stop_if_paused; step base-noop;  $S/heavy.sh base-threaded-noop $GEN || exit 1
stop_if_paused; step apply;      $PY $S/apply_boundary.py $L $ENG
stop_if_paused; step proto-cold; $S/heavy.sh proto-threaded-cold $GEN || exit 1
stop_if_paused; step proto-edit1; $S/game_edit.sh; $S/heavy.sh proto-threaded-edit1 $GEN || exit 1
stop_if_paused; step proto-edit2; $S/game_edit.sh; $S/heavy.sh proto-threaded-edit2 $GEN || exit 1
stop_if_paused; step base-edit2-revert; $PY $S/apply_boundary.py $L $ENG --revert; $S/game_edit.sh; $S/heavy.sh base-threaded-edit2 $GEN || exit 1
stop_if_paused; step proto-st;   $PY $S/apply_boundary.py $L $ENG; $S/heavy.sh proto-single-cold $GEN -Dwasm_threads=false || exit 1
stop_if_paused; step proto-st-edit; $S/game_edit.sh; $S/heavy.sh proto-single-edit1 $GEN -Dwasm_threads=false || exit 1
echo "=== all done $(date +%T)"
