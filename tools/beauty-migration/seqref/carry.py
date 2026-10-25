#!/usr/bin/env python3
"""carry.py NEW_INV.tsv OLD_CLASSES.tsv OUT.tsv HEADER_NOTE: give each site of a
fresh inventory (residue.py output on a newer tree) the class and note of the
same site in an older classified inventory, matched by (function, accessor,
ordinal within the function). Sites without a match keep `open`."""
import sys
from collections import Counter, defaultdict

new_p, old_p, out_p = sys.argv[1:4]
note = sys.argv[4] if len(sys.argv) > 4 else ''
old = defaultdict(list)
hdr = []
for l in open(old_p):
    if l.startswith('#'):
        if not l.startswith('# class'):
            hdr.append(l)
        continue
    f = l.rstrip('\n').split('\t')
    old[(f[2], f[3])].append((f[0], f[6] if len(f) > 6 else ''))
seen = Counter()
rows = []
for l in open(new_p):
    if l.startswith('# '):
        continue
    f = l.rstrip('\n').split('\t')
    key = (f[2], f[3])
    k = seen[key]
    seen[key] += 1
    cls, nt = (old[key][k] if k < len(old[key]) else ('open', ''))
    rows.append([cls] + f[1:6] + [nt])
with open(out_p, 'w') as f:
    f.write(''.join(hdr))
    if note:
        f.write('# ' + note + '\n')
    f.write('# class\tsite\tfunction\taccessor\tkind\tin-loop\tnote\n')
    for r in rows:
        f.write('\t'.join(r) + '\n')
print(len(rows), Counter(r[0] for r in rows).most_common())
