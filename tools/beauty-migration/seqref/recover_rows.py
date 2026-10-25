#!/usr/bin/env python3
"""recover_rows.py OUT.tsv TRANSCRIPT...: the residue-class rows (class, site,
function, kind, accessor, consumers) that appear in session transcripts, from
the pre-reboot SCRATCH/sv/residue-classes.txt (main 98ba0b961 line numbers)."""
import re
import sys
from collections import Counter

pat = re.compile(r'(#8858|consumer|view|now)\\t(src/[a-z_/]+\.tl):(\d+)\\t([^\\\s]+)'
                 r'\\t([a-z/-]+)\\t([a-z-]+)\\t([^\\"]*)')
rows = set()
for p in sys.argv[2:]:
    s = open(p, encoding='utf-8', errors='replace').read()
    rows |= set(m.groups() for m in pat.finditer(s))
with open(sys.argv[1], 'w') as f:
    for r in sorted(rows, key=lambda r: (r[1], int(r[2]))):
        f.write('\t'.join(r) + '\n')
print(len(rows), dict(Counter(r[0] for r in rows)), dict(Counter(r[1] for r in rows)))
