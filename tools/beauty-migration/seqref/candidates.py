#!/usr/bin/env python3
"""candidates.py INVENTORY.tsv AVOID_FUNCS.txt OUT_LINES [EXCLUDE_FUNCS...]:
site lines eligible for flipping: classes open/now/consumer/view, not in an
avoided function, not in the #9135 line ranges, not in EXCLUDE_FUNCS."""
import sys

avoid = set(open(sys.argv[2]).read().split())
exclude = set(sys.argv[4:])
RANGES = [(113815, 113890), (123886, 124340)]
out = []
for line in open(sys.argv[1]):
    if line.startswith('# '):
        continue
    f = line.rstrip('\n').split('\t')
    cls, site, func = f[0], f[1], f[2]
    ln = int(site.split(':')[1])
    if cls not in ('open', 'now', 'consumer', 'view'):
        continue
    if func in avoid or func in exclude:
        continue
    if any(a <= ln <= b for a, b in RANGES):
        continue
    out.append(ln)
open(sys.argv[3], 'w').write('\n'.join(str(x) for x in sorted(set(out))) + '\n')
print(len(set(out)), 'candidate lines')
