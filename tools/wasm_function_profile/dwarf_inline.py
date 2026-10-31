"""Attribute a function's code bytes to the calls LLVM inlined into it.

usage: python dwarf_inline.py <object.o> <linkage_name> [depth=1] [top=40]

Runs `llvm-dwarfdump --name=<linkage_name> --show-children`, then for every
DW_TAG_inlined_subroutine at the requested nesting depth (1 = inlined
directly into the function) sums its address ranges, grouped by the
inlined callee. Ranges of one inlined call can interleave with others, but
the per-callee totals are a good attribution of where the bytes come from.
"""
import collections, re, subprocess, sys

BIN = 'C:/Users/User/.labelle/providers/github.com/labelle-toolkit/labelle-web/emsdk/v1/x86_64-windows/4.0.9-3bcf1dcd01f0/upstream/bin'
obj, name = sys.argv[1], sys.argv[2]
want_depth = int(sys.argv[3]) if len(sys.argv) > 3 else 1
top = int(sys.argv[4]) if len(sys.argv) > 4 else 40
txt = subprocess.run([BIN + '/llvm-dwarfdump.exe', '--name=' + name, '--show-children', obj],
                     capture_output=True, text=True, encoding='utf-8', errors='replace').stdout

die_re = re.compile(r'^0x[0-9a-f]+:( +)(DW_TAG_\w+)')
range_re = re.compile(r'\[0x([0-9a-f]+), 0x([0-9a-f]+)\)')
dies = []  # (depth, tag, attrs-text)
cur = None
base_indent = None
for line in txt.splitlines():
    m = die_re.match(line)
    if m:
        indent = len(m.group(1))
        if base_indent is None: base_indent = indent
        cur = {'depth': (indent - base_indent) // 2, 'tag': m.group(2), 'lines': []}
        dies.append(cur)
    elif cur is not None:
        cur['lines'].append(line)

def die_size(d):
    text = '\n'.join(d['lines'])
    lo = re.search(r'DW_AT_low_pc\s+\(0x([0-9a-f]+)\)', text)
    hi = re.search(r'DW_AT_high_pc\s+\(0x([0-9a-f]+)\)', text)
    if lo and hi:
        return int(hi.group(1), 16) - int(lo.group(1), 16)
    if 'DW_AT_ranges' in text:
        part = text.split('DW_AT_ranges', 1)[1].split('DW_AT_call', 1)[0]
        return sum(int(b, 16) - int(a, 16) for a, b in range_re.findall(part))
    return 0

def origin(d):
    m = re.search(r'DW_AT_abstract_origin\s+\(0x[0-9a-f]+ "(.*)"\)', '\n'.join(d['lines']))
    return m.group(1) if m else '?'

def call_line(d):
    m = re.search(r'DW_AT_call_line\s+\((\d+)\)', '\n'.join(d['lines']))
    return int(m.group(1)) if m else 0

root = dies[0] if dies else None
total = die_size(root) if root else 0
agg = collections.defaultdict(lambda: [0, 0, set()])
for d in dies[1:]:
    if d['tag'] == 'DW_TAG_subprogram' and d['depth'] == 0:
        break  # another function with the same name
    if d['tag'] == 'DW_TAG_inlined_subroutine' and d['depth'] == want_depth:
        o = re.sub(r'__anon_\d+', '', origin(d))
        if '(' in o and ').' in o:
            o = o.split('(', 1)[0] + '(...).' + o.rsplit(').', 1)[1]
        o = o[:130]
        a = agg[o]; a[0] += die_size(d); a[1] += 1; a[2].add(call_line(d))
covered = sum(v[0] for v in agg.values())
print(f'{name}: {total} B; inlined at depth {want_depth}: {covered} B in {sum(v[1] for v in agg.values())} call sites')
for o, (size, n, lines) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:top]:
    ls = sorted(lines)
    span = f'{ls[0]}..{ls[-1]}' if len(ls) > 1 else str(ls[0])
    print(f'{size:8d} B {n:4d}x  lines {span:>12}  {o}')
