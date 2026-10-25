#!/usr/bin/env python3
"""fnchanged.py A.tl B.tl NAME...: for each top-level define/defmacro NAME,
whether its text differs between A and B (or is missing from one)."""
import re
import sys


def forms(path):
    src = open(path).read()
    starts = [m.start() for m in re.finditer(r'^\(', src, re.M)] + [len(src)]
    out = {}
    for a, b in zip(starts, starts[1:]):
        m = re.match(r'\((?:define|defmacro|defenum|defstruct)\s+\(?([^\s()\[\]]+)', src[a:a + 200])
        if m:
            out[m.group(1)] = src[a:b]
    return out


fa = forms(sys.argv[1])
fb = forms(sys.argv[2])
for n in sys.argv[3:]:
    if n not in fa or n not in fb:
        print('%-48s missing (%s)' % (n, 'A' if n not in fa else 'B'))
    else:
        print('%-48s %s' % (n, 'same' if fa[n] == fb[n] else 'CHANGED'))
