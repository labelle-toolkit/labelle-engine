"""Add a local-only `profile-game` step to a GENERATED wasm build.zig: it
compiles just the game static library (no emcc link) and installs
libgame.a under zig-out/profile/ so per-function sizes can be read with
llvm-nm. Idempotent. Never commit the result anywhere.
usage: python add_profile_step.py <.labelle/bgfx_wasm/build.zig>"""
import sys
from pathlib import Path
p = Path(sys.argv[1]); s = p.read_text(encoding='utf-8')
MARK = '// wp2b profile-game step (local measurement only)'
if MARK in s:
    print('already patched'); sys.exit(0)
anchor = '    // post_wire (design §4)'
assert anchor in s, 'anchor not found'
snippet = f'''    {MARK}
    {{
        const wp2b_step = b.step("profile-game", "compile only the game library");
        const wp2b_inst = b.addInstallArtifact(wasm, .{{ .dest_dir = .{{ .override = .{{ .custom = "profile" }} }} }});
        wp2b_step.dependOn(&wp2b_inst.step);
    }}

'''
s = s.replace(anchor, snippet + anchor, 1)
p.write_text(s, encoding='utf-8'); print('patched')
