"""Before/after table for labelle-engine#922 profile runs.

usage: python summarize.py <results_dir> <variant> [<variant> ...]
Each variant dir is produced by profile.sh.
"""
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
variants = sys.argv[2:]
GiB = 2**30


def load(p):
    try:
        return json.loads(Path(p).read_text(encoding='utf-8'))
    except Exception:
        return None


def game_proc(run):
    """The `zig build-lib` that compiles the game Zcu (the big one)."""
    if not run:
        return None
    procs = [p for p in run.get('long_processes', []) if 'build-lib' in p['argv']]
    return max(procs, key=lambda p: p['peak_private_bytes']) if procs else None


def link_secs(run):
    if not run:
        return None
    t = [p['seconds'] for p in run.get('long_processes', []) if p['name'] in ('wasm-opt.exe',) or ('emcc' in p['argv'] and p['name'] == 'python.exe')]
    return max(t) if t else None


def llvm_passes(vdir):
    """Sum wall seconds per pass over every time-report section."""
    passes = {}
    for f in sorted(vdir.glob('game-report-step-*-llvm.txt')):
        for line in f.read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.match(r'\s*(?:[\d.]+\s+\(\s*[\d.]+%\)\s+){3}([\d.]+)\s+\(\s*[\d.]+%\)\s+(.+)$', line)
            if m and m.group(2).strip() != 'Total':
                passes[m.group(2).strip()] = passes.get(m.group(2).strip(), 0.0) + float(m.group(1))
    return passes


rows = []
sym = {}
for v in variants:
    d = root / v
    rep = load(d / 'game-report.json')
    clean = load(d / 'game-clean.json')
    full = load(d / 'full.json')
    timing = load(d / 'game-report-timing.json')
    s = load(d / 'game-symbols.json')
    sym[v] = s
    stats = None
    if timing:
        for r in timing.get('results', []):
            if 'stats' in r and 'game' in r['step']:
                stats = r
    gp_rep, gp_clean = game_proc(rep), game_proc(clean)
    wasm = None
    ws = d / 'wasm-size.txt'
    if ws.exists() and ws.read_text().strip():
        wasm = int(ws.read_text().split()[0])
    rows.append({
        'variant': v,
        'clean_compile_s': gp_clean['seconds'] if gp_clean else None,
        'clean_peak_gib': round(gp_clean['peak_private_bytes'] / GiB, 2) if gp_clean else None,
        'report_compile_s': gp_rep['seconds'] if gp_rep else None,
        'report_peak_gib': round(gp_rep['peak_private_bytes'] / GiB, 2) if gp_rep else None,
        'llvm_emit_s': round(stats['stats']['real_llvm_emit_ns'] / 1e9, 1) if stats else None,
        'sema_s': round(stats['stats']['cpu_sema_ns'] / 1e9, 1) if stats else None,
        'codegen_s': round(stats['stats']['cpu_codegen_ns'] / 1e9, 1) if stats else None,
        'link_s': link_secs(full),
        'wasm_bytes': wasm,
        'code_bytes': s['total_code_bytes'] if s else None,
        'functions': s['functions'] if s else None,
        'largest': s['top'][0] if s else None,
        'passes': llvm_passes(d),
    })

cols = [('variant', 'variant'), ('clean_compile_s', 'game compile s (edit rebuild)'), ('clean_peak_gib', 'game peak private GiB'),
        ('report_compile_s', 'compile s (--time-report)'), ('report_peak_gib', 'peak GiB (--time-report)'),
        ('llvm_emit_s', 'LLVM emit s'), ('sema_s', 'sema CPU s'), ('codegen_s', 'codegen CPU s'), ('link_s', 'emcc link s'),
        ('wasm_bytes', 'final .wasm B'), ('code_bytes', 'game obj code B'), ('functions', 'functions')]
print('| ' + ' | '.join(c[1] for c in cols) + ' |')
print('|' + '---|' * len(cols))
for r in rows:
    print('| ' + ' | '.join('' if r[k] is None else str(r[k]) for k, _ in cols) + ' |')

print('\nLargest function per variant:')
for r in rows:
    if r['largest']:
        print(f"  {r['variant']}: {r['largest']['bytes']} B {r['largest']['name']}")

print('\nCluster sizes (bytes / largest function):')
names = list(next(iter(s for s in sym.values() if s))['clusters'].keys())
print('| cluster | ' + ' | '.join(variants) + ' |')
print('|---|' + '---:|' * len(variants))
for n in names:
    cells = []
    for v in variants:
        c = sym[v]['clusters'][n] if sym[v] else None
        cells.append(f"{c['bytes']} ({c['functions']} fn, max {c['largest']})" if c else '')
    print(f'| {n} | ' + ' | '.join(cells) + ' |')

print('\nTop LLVM passes (wall s, summed over time-report sections):')
allp = {}
for r in rows:
    for k, v in r['passes'].items():
        allp[k] = max(allp.get(k, 0), v)
top = sorted(allp, key=lambda k: -allp[k])[:15]
print('| pass | ' + ' | '.join(variants) + ' |')
print('|---|' + '---:|' * len(variants))
for k in top:
    print(f'| {k} | ' + ' | '.join(str(round(r['passes'].get(k, 0), 2)) for r in rows) + ' |')
