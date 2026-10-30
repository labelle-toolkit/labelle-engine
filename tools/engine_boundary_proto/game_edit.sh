#!/bin/bash
# Simulate a game-only source edit in the generated tree (what `labelle generate`
# copies from FP's scripts/): change a constant-folded statement in a script.
f=D:/prj/labelle-toolkit/epic-528/fp-engine-boundary/.labelle/bgfx_wasm/scripts/playing/00_game_time.zig
echo "comptime { _ = $(date +%s); } // labelle-engine#923 game-only edit probe" >> $f
tail -1 $f
