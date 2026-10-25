#!/usr/bin/env python3
# cgfns.py ANNOTATE.txt NAMES.txt: inclusive Ir of each TypeLisp function name
# in NAMES.txt (kebab-case) from a `callgrind_annotate --inclusive=yes` dump.
import re
import sys

ann, names = sys.argv[1], sys.argv[2]
cost = {}
for line in open(ann):
    m = re.match(r'\s*([\d,]+) \([^)]*\)\s+\S*:_tl_compiler_optimize_compiler_optimize_([A-Za-z0-9_]+) ', line)
    if m:
        cost.setdefault(m.group(2), int(m.group(1).replace(',', '')))


def mangle(n):
    return n.replace('-', '_').replace('!', '_bang').replace('?', '_p')


rows = []
for n in open(names):
    n = n.strip()
    if n:
        rows.append((cost.get(mangle(n), 0), n))
rows.sort(reverse=True)
for c, n in rows:
    if c:
        print(f'{c:>15,}  {n}')
print('absent:', sum(1 for c, _ in rows if not c), 'of', len(rows))
