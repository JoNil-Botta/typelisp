#!/usr/bin/env python3
# sigs.py FILE SITES.TSV: for each enclosing function in SITES.TSV (from
# sites.py), print its parameter list (one line) and its site count.
import re
import sys
from collections import OrderedDict

path, sites = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
counts = OrderedDict()
for row in open(sites):
    f = row.split('\t')
    counts[f[1]] = counts.get(f[1], 0) + 1
defre = re.compile(r'^\((?:define|define-macro|defmacro) \(?([^\s()]+)')
starts = {}
for n, line in enumerate(lines):
    m = defre.match(line)
    if m and m.group(1) not in starts:
        starts[m.group(1)] = n
for name, c in counts.items():
    n = starts.get(name)
    if n is None:
        print(f'{c}\t{name}\t?')
        continue
    sig = []
    for k in range(n, min(n + 14, len(lines))):
        sig.append(lines[k].strip())
        if re.search(r'\)\s*:\s*[^\s]', lines[k]) and k > n or (k == n and re.search(r'\]\)\s*:', lines[k])):
            break
    params = re.findall(r'\[([a-z0-9?!*-]+) : ([^\]]+)\]', ' '.join(sig))
    print(f'{c}\t{name}\t' + ' '.join(f'{p}:{t}' for p, t in params))
