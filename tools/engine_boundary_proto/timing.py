import json,sys,collections,re
d=json.load(open(sys.argv[1],encoding='utf-8'))
for r in d['results']:
    if 'stats' not in r: continue
    if 'game' not in r['step']: continue
    st=r['stats']
    print(r['step'], 'wall',round(r['wall_seconds'],1))
    for k,v in st.items(): print('  ',k, v if not k.endswith('_ns') else round(v/1e9,2))
    agg=collections.Counter(); tot=collections.Counter()
    for dcl in r['declarations']:
        f=dcl['file'].replace(chr(92),'/')
        m=re.search(r'(deps/[^/]+|zig-pkg/[^/]+|lib/std|bgfx_wasm/[^/]+)',f)
        key=m.group(1) if m else f[-50:]
        t=dcl['sema_ns']+dcl['codegen_ns']
        agg[key]+=t
        tot['all']+=t
    print('  sema+codegen by origin (s):', round(tot['all']/1e9,1))
    for k,v in agg.most_common(30): print(f'    {v/1e9:7.2f} {k}')
