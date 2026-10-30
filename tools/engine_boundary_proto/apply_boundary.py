"""Apply the labelle-engine#923 engine-rt boundary prototype to a GENERATED
FP wasm tree (`.labelle/bgfx_wasm`). Local measurement aid only: the real
change belongs in labelle-assembler's templates.

usage: python apply_boundary.py <.labelle dir> <engine checkout> [--revert]
"""
import shutil, sys
from pathlib import Path

labelle = Path(sys.argv[1]); engine = Path(sys.argv[2]); revert = '--revert' in sys.argv
gen = labelle / 'bgfx_wasm'; dep = labelle / 'deps' / 'labelle-engine'
MARK = '// labelle-engine#923 prototype'

BUILD_SNIPPET = f'''
    {MARK}: the TMX loader as an independently compiled static
    // library (own Zcu / LLVM module). Same target/optimize; the
    // MultiThreaded walk below reaches it through link_objects, so its
    // single_threaded flag matches the game's.
    const engine_rt = b.addLibrary(.{{
        .name = "labelle_engine_rt",
        .linkage = .static,
        .root_module = b.createModule(.{{
            .root_source_file = engine_dep.path("src/boundary/tmx_rt.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{{.{{ .name = "tilemap", .module = gfx_mod.import_table.get("tilemap").? }}}},
        }}),
    }});
    wasm.root_module.linkLibrary(engine_rt);
'''
ANCHOR_BUILD = '    wasm.root_module.linkLibrary(bgfx);\n'
MAIN_SNIPPET = f'{MARK}: opt into the engine-rt TMX boundary.\npub const labelle_engine_rt_tmx = true;\n'
ANCHOR_MAIN = 'pub const Game = AssembledGame;\n'

def patch(path, anchor, snippet):
    s = path.read_text(encoding='utf-8')
    if revert:
        if snippet in s:
            s = s.replace(snippet, '')
    elif MARK not in s:
        assert anchor in s, f'anchor missing in {path}'
        s = s.replace(anchor, anchor + snippet, 1)
    path.write_text(s, encoding='utf-8', newline='\n')

patch(gen / 'build.zig', ANCHOR_BUILD, BUILD_SNIPPET)
patch(gen / 'main.zig', ANCHOR_MAIN, MAIN_SNIPPET)

if not revert:
    (dep / 'src' / 'boundary').mkdir(exist_ok=True)
    for f in ['layout.zig', 'tmx_abi.zig', 'tmx_adapter.zig', 'tmx_rt.zig']:
        shutil.copy2(engine / 'src' / 'boundary' / f, dep / 'src' / 'boundary' / f)
    shutil.copy2(engine / 'src' / 'tilemap_runtime.zig', dep / 'src' / 'tilemap_runtime.zig')
print('reverted' if revert else 'applied')
