#!/usr/bin/env python3
"""writeaudit.py ORIG.tl NEW.tl: for every top-level define whose text differs
between ORIG and NEW, the lines of NEW's version that write IR storage
(seq-set!, a slot store, replace!, an edge application, a -set! helper,
builder-set!), or `clean` when there are none."""
import re
import sys


def forms(path):
    src = open(path).read()
    starts = [m.start() for m in re.finditer(r'^\(', src, re.M)] + [len(src)]
    out = {}
    for a, b in zip(starts, starts[1:]):
        m = re.match(r'\((?:define|defmacro)\s+\(?([^\s()\[\]]+)', src[a:a + 200])
        if m:
            out[m.group(1)] = (src[:a].count('\n') + 1, src[a:b])
    return out


W = re.compile(r'seq-set!|\(set!\s*\(array-ref [^)]*slots|replace!|apply-edge|-set!\b|builder-set!')
o = forms(sys.argv[1])
n = forms(sys.argv[2])
changed = [k for k in n if k in o and n[k][1] != o[k][1]]
for k in sorted(changed, key=lambda k: n[k][0]):
    ln, body = n[k]
    hits = [(ln + i, l.strip()) for i, l in enumerate(body.split('\n')) if W.search(l)]
    print('%-50s %s' % (k, 'clean' if not hits else 'WRITES'))
    for i, l in hits:
        print('      %d: %s' % (i, l[:100]))
print(len(changed), 'changed functions')
