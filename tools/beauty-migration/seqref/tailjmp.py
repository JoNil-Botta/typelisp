#!/usr/bin/env python3
# tailjmp.py MAIN.s BRANCH.s: for each function in both files, the tail jumps
# (`jmp _tl_...` to another function); prints functions whose set shrank.
import re
import sys


def tails(path):
    out = {}
    cur = None
    fn_re = re.compile(r'^(_tl_[A-Za-z0-9_]+):$')
    jmp_re = re.compile(r'^\s+jmp (_tl_[A-Za-z0-9_]+)\s*$')
    with open(path) as f:
        for line in f:
            m = fn_re.match(line)
            if m:
                cur = m.group(1)
                out.setdefault(cur, [])
                continue
            m = jmp_re.match(line)
            if m and cur is not None:
                out[cur].append(m.group(1))
    return out


a = tails(sys.argv[1])
b = tails(sys.argv[2])
lost = 0
for name in sorted(set(a) & set(b)):
    ta = sorted(a[name])
    tb = sorted(b[name])
    if ta != tb:
        gone = [t for t in set(ta) if ta.count(t) > tb.count(t)]
        if gone:
            lost += 1
            print(name, 'lost', gone, 'now', tb)
only_a = sorted(n for n in set(a) - set(b) if a[n])
print('functions only in main with tail jumps:', len(only_a))
for n in only_a:
    print('  ', n, a[n])
print('functions with a lost tail jump:', lost)
