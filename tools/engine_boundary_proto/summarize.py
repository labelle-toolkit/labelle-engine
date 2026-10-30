import json, sys, glob, os
d = sys.argv[1]
rows = []
for f in sorted(glob.glob(os.path.join(d, '*.json'))):
    j = json.load(open(f, encoding='utf-8'))
    if 'run' not in j: continue
    game = rt = link = None; game_peak = None
    for p in j.get('long_processes', []):
        a = p['argv']
        if p['name'] == 'zig.exe' and 'build-lib' in a and p['peak_private_bytes'] > 2**31:
            game = p['seconds']; game_peak = p['peak_private_bytes']
        if p['name'] == 'wasm-opt.exe': link = p['seconds']
        if p['name'] == 'python.exe' and 'emcc.py' in a: link = p['seconds']
    if game_peak is None:
        tp = [t for t in j['top_processes'] if 'build-lib' in t['argv']]
        game_peak = tp[0]['peak_private_bytes'] if tp else None
    rows.append((j['run'], j['exit'], j['wall_seconds'], game, round(game_peak / 2**30, 2) if game_peak else None, link,
                 round(j['tree_peak_private_bytes'] / 2**30, 2)))
print('| run | exit | total s | game Zcu compile s | game zig peak GiB | emcc link s | tree peak GiB |')
print('|---|---|---:|---:|---:|---:|---:|')
for r in rows: print('| ' + ' | '.join('' if v is None else str(v) for v in r) + ' |')
