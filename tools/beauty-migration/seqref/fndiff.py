#!/usr/bin/env python3
"""fndiff.py A.s B.s [N]: functions whose bodies differ between two assembly
files (local .L labels normalized), with line-count deltas; at most N shown."""
import re
import sys

LABEL = re.compile(r'^(_tl_[\w$.]+|[A-Za-z_][\w$.]*):\s*$')
LOCAL = re.compile(r'\.L[\w.$-]*')


def funcs(path):
    out = {}
    cur = None
    for line in open(path, errors='replace'):
        m = LABEL.match(line)
        if m and not line.startswith('.L'):
            cur = m.group(1)
            out[cur] = []
            continue
        if cur is not None:
            out[cur].append(LOCAL.sub('.L', line.rstrip('\n')))
    return out


a = funcs(sys.argv[1])
b = funcs(sys.argv[2])
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 20
diff = [n for n in a if n in b and a[n] != b[n]]
only_a = [n for n in a if n not in b]
only_b = [n for n in b if n not in a]
print('functions differing: %d, only in A: %d, only in B: %d' % (len(diff), len(only_a), len(only_b)))
for n in diff[:limit]:
    print('  %s  %d -> %d lines' % (n, len(a[n]), len(b[n])))
for n in only_a[:limit]:
    print('  only A: %s' % n)
for n in only_b[:limit]:
    print('  only B: %s' % n)
