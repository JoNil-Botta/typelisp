#!/usr/bin/env python3
# fnviews.py FILE SITES.TSV: per enclosing function of SITES.TSV, the number of
# `shared-view` and `-seq-ref` occurrences in its body, plus totals.
import re
import sys

path, sites = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
names = []
for row in open(sites):
    f = row.split('\t')
    if f[1] not in names:
        names.append(f[1])
defre = re.compile(r'^\((?:define|define-macro|defmacro|defstruct|defenum|cfg|test|import)\b')
namere = re.compile(r'^\((?:define|define-macro|defmacro) \(?([^\s()]+)')
bodies = {}
cur = None
for line in lines:
    if defre.match(line):
        m = namere.match(line)
        cur = m.group(1) if m else None
        if cur is not None:
            bodies.setdefault(cur, [])
        continue
    if cur is not None:
        bodies[cur].append(line)
tv = ts = 0
for n in names:
    body = '\n'.join(bodies.get(n, []))
    v = len(re.findall(r'shared-view', body))
    s = len(re.findall(r'-seq-ref\b', body))
    tv += v
    ts += s
    print(f'{v}\t{s}\t{n}')
print(f'total shared-view {tv} seq-ref {ts} in {len(names)} functions')
