#!/usr/bin/env python3
"""cgdiff.py A.out B.out [N]: per-function self and inclusive cost deltas
between two callgrind outputs (via callgrind_annotate), largest |delta| first."""
import re
import subprocess
import sys


def load(path, inclusive):
    args = ['callgrind_annotate', '--threshold=100']
    if inclusive:
        args.append('--inclusive=yes')
    out = subprocess.run(args + [path], capture_output=True, text=True).stdout
    total = 0
    d = {}
    for line in out.splitlines():
        m = re.match(r'^\s*([\d,]+)\s+\(\s*[\d.]+%\)\s+(?:\S+:)?(\S+)', line)
        if m:
            d[m.group(2)] = d.get(m.group(2), 0) + int(m.group(1).replace(',', ''))
        m2 = re.match(r'^\s*([\d,]+)\s+\(100.0%\)\s+PROGRAM TOTALS', line)
        if m2:
            total = int(m2.group(1).replace(',', ''))
    return total, d


n = int(sys.argv[3]) if len(sys.argv) > 3 else 25
for inclusive in (False, True):
    ta, a = load(sys.argv[1], inclusive)
    tb, b = load(sys.argv[2], inclusive)
    rows = []
    for k in set(a) | set(b):
        delta = b.get(k, 0) - a.get(k, 0)
        if delta and not k.startswith('0x'):
            rows.append((delta, b.get(k, 0), k))
    rows.sort(key=lambda r: -abs(r[0]))
    print('=== %s  total A %d B %d delta %+d' % ('inclusive' if inclusive else 'self', ta, tb, tb - ta))
    for delta, val, k in rows[:n]:
        print('  %+14d %14d %s' % (delta, val, k))
