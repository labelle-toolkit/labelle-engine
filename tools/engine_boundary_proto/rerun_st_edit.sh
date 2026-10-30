#!/bin/bash
# Re-run proto-single-edit1 after the main session and link-opt agent have had the lock
# (coordinator order). Counts lock release events; then heavy.sh waits >=90 s itself.
W="C:/Users/User/AppData/Local/Temp/claude/D--prj-labelle-toolkit/59b740bb-78d4-4495-adab-2a9403264606/scratchpad/wp4"
LOCK=D:/prj/labelle-toolkit/epic-528/.heavy-lock
releases=0; held=0
[ -d $LOCK ] && held=1
echo "start $(date +%T) held=$held"
while [ $releases -lt 2 ]; do
  if [ -d $LOCK ]; then held=1; elif [ $held = 1 ]; then held=0; releases=$((releases+1)); echo "release seen #$releases $(date +%T)"; fi
  sleep 10
done
$W/game_edit.sh
$W/heavy.sh proto-single-edit1 D:/prj/labelle-toolkit/epic-528/fp-engine-boundary/.labelle/bgfx_wasm -Dwasm_threads=false
