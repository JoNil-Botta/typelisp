#!/usr/bin/env python3
"""reborrow.py FILE.tl DIFF: for every top-level form a -U0 diff touches, the
`(& name)` / `(&mut name)` uses in it, so re-borrows of names that are now
references (#9137) can be checked by eye."""
import re
import sys

L = open(sys.argv[1]).read().split('\n')
diff = open(sys.argv[2]).read()
touched = [int(m.group(1)) for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)', diff, re.M)]
tops = [i + 1 for i, l in enumerate(L) if l.startswith('(')]
spans = {}
for ln in touched:
    t = max(x for x in tops if x <= ln)
    nxt = min([x for x in tops if x > t] + [len(L)])
    spans[t] = nxt
for t, nxt in sorted(spans.items()):
    m = re.match(r'\((?:define|defmacro)\s+\(?([^\s()\[\]]+)', L[t - 1])
    name = m.group(1) if m else L[t - 1][:40]
    hits = [(i + 1, l.strip()) for i, l in enumerate(L[t - 1:nxt - 1], start=t - 1)
            if re.search(r'\(&(?:mut)?\s+[a-z][a-z0-9?!.-]*\)', l)]
    if hits:
        print('==', name)
        for i, l in hits:
            print('   %d: %s' % (i, l[:110]))
