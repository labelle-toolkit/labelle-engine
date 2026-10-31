"""Per-function code size of an archive/object (llvm-nm -S), top N and
named-cluster totals.
usage: python symbols.py <libgame.a> <out_prefix> [top_n]"""
import json, re, subprocess, sys, collections
NM = 'C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0/upstream/bin/llvm-nm.exe'
lib, prefix = sys.argv[1], sys.argv[2]
top_n = int(sys.argv[3]) if len(sys.argv) > 3 else 30
txt = subprocess.run([NM, '-S', '--defined-only', lib], capture_output=True, text=True, encoding='utf-8', errors='replace').stdout
rows = []
for line in txt.splitlines():
    parts = line.split(' ', 3)
    if len(parts) == 4 and parts[2] in ('T', 't'):
        try: rows.append((int(parts[1], 16), parts[3]))
        except ValueError: pass
rows.sort(reverse=True)
total = sum(s for s, _ in rows)
# Short display names: strip the long Game type argument lists.
def short(n):
    n = re.sub(r'GameConfigWithYAxis\(.*', 'GameConfigWithYAxis(...)', n)
    return n[:160]
clusters = collections.OrderedDict([
    ('startup main.main', lambda n: n == 'main.main'),
    ('inspector drawEntityDetail', lambda n: 'drawEntityDetail' in n),
    ('inspector drawEntityBrowser', lambda n: 'drawEntityBrowser' in n),
    ('inspector other root.draw*', lambda n: n.startswith('root.') and 'drawEntity' not in n),
    ('load.Mixin.* (all)', lambda n: n.startswith('game.save_load.load.Mixin(')),
    ('save.Mixin.* (all)', lambda n: n.startswith('game.save_load.save.Mixin(')),
    ('main.* (generated, all)', lambda n: n.startswith('main.')),
])
cl = {k: {'bytes': 0, 'functions': 0, 'largest': 0} for k in clusters}
for s, n in rows:
    for k, f in clusters.items():
        if f(n):
            cl[k]['bytes'] += s; cl[k]['functions'] += 1; cl[k]['largest'] = max(cl[k]['largest'], s)
with open(prefix + '-functions.tsv', 'w', encoding='utf-8') as f:
    for s, n in rows: f.write(f'{s}\t{n}\n')
res = {'archive': lib, 'functions': len(rows), 'total_code_bytes': total,
       'top': [{'bytes': s, 'name': short(n)} for s, n in rows[:top_n]], 'clusters': cl}
open(prefix + '-symbols.json', 'w', encoding='utf-8').write(json.dumps(res, indent=2))
print('functions', len(rows), 'total code', total)
for s, n in rows[:top_n]: print(f'{s:8d}  {short(n)}')
print('clusters:')
for k, v in cl.items(): print(f"  {v['bytes']:8d} B in {v['functions']:4d} fns (largest {v['largest']:7d})  {k}")
