import collections,sys
rows=[l.rstrip('\n').split('\t',1) for l in open(sys.argv[1],encoding='utf-8')]
tot=sum(int(s) for s,_ in rows)
gen=collections.Counter(); con=collections.Counter()
specialized=0; concrete=0
for s,n in rows:
    s=int(s)
    top=n.split('.')[0].split('(')[0]
    is_gen = ('(' in n) or ('__anon' in n) or n.startswith('main.')
    if is_gen: gen[top]+=s; specialized+=s
    else: con[top]+=s; concrete+=s
print('total code',tot,'generic/specialized',specialized,'concrete',concrete, 'nfuncs',len(rows))
print('top concrete namespaces:')
for k,v in con.most_common(45): print(f'  {v:9d} {k}')
print('top generic namespaces:')
for k,v in gen.most_common(25): print(f'  {v:9d} {k}')
