#!/usr/bin/env python3
"""reclass.py INV.tsv R4_REVERTED.tsv R4_KEPT R5_FIXES.tsv R5_KEPT AVOID OUT.tsv:
the inventory with each open site's class from the batch-4 flip-and-revert runs.

  run r4: site flips plus value/type copies at the boundary, no signature change
  run r5: the same plus a named lifetime on an elided reference parameter

classes
  ok          converts in r4 (borrow, copy only the value/type it returns)
  wait-9094   converts in r5 only because a parameter gets a named lifetime, or its
              r4 blocker is a let-bound borrow of an elided-lifetime parameter
              (the old #8858 class; #9094)
  own         the element itself moves into new storage or a result: builder push,
              array/field store, a match/if arm or return yielding it, a constructor
              argument (needs a consuming rewrite, #9013 step B, or a whole copy)
  consumer    passed to a function that takes it by value and rebuilds or returns it
              (a rewrite consumer; converting it copies on the unchanged path)
  walk        the walk macros: their callbacks take elements by value
  avoid-9135  in a function #9135 changes
  other       anything else (the reason column says what)"""
import re
import sys

inv, rev4, kept4, fix5, kept5, avoid_p, out = sys.argv[1:8]
avoid = set(open(avoid_p).read().split())
reason4 = {}
for l in open(rev4):
    ln, fn, rnd, msg = l.rstrip('\n').split('\t', 3)
    reason4[int(ln)] = msg
k4 = {int(x) for x in open(kept4).read().split()}
k5 = {int(x) for x in open(kept5).read().split()}
life5 = set()
for l in open(fix5):
    f = l.rstrip('\n').split('\t')
    if f[3].startswith('lifetime:'):
        life5.add(f[0])


def cls_of(msg):
    if 'builder-push!' in msg or 'array assignment' in msg or 'assignment type mismatch' in msg:
        return 'own'
    if 'match arm result' in msg or 'if branches must match' in msg or 'return type mismatch' in msg:
        return 'own'
    m = re.search(r"call `([^`]+)` argument", msg)
    if m:
        callee = m.group(1).split('.')[-1]
        if callee[:1].isupper() or callee in ('compiler-ir-instr-seq2', 'compiler-ir-value-seq1'):
            return 'own'
        return 'consumer'
    if 'would escape lexical scope' in msg or 'region-tagged' in msg:
        return 'escape'
    return 'other'


rows = []
for l in open(inv):
    if l.startswith('# '):
        continue
    f = l.rstrip('\n').split('\t')
    cls, site, fn = f[0], f[1], f[2]
    ln = int(site.split(':')[1])
    note = f[6] if len(f) > 6 else ''
    if cls == '#9094':
        cls = 'wait-9094'
    elif cls == '#8901':
        cls = 'wait-8901'
    elif fn in avoid or 113815 <= ln <= 113890 or 123886 <= ln <= 124340:
        cls, note = 'avoid-9135', note
    elif fn in ('opt-instrs-walk', 'opt-blocks-walk', 'opt-blocks-map-walk'):
        cls, note = 'walk', 'the walk callbacks take elements by value'
    elif ln in k4:
        cls, note = 'ok', 'converts with a copy of the returned value/type'
    elif ln in k5 or fn in life5:
        cls, note = 'wait-9094', 'needs a named lifetime on an elided reference parameter'
    else:
        msg = reason4.get(ln, '')
        c = cls_of(msg)
        if c == 'escape':
            c = 'own'
        cls = c
        note = re.sub(r'^error\[[^\]]*\]: typecheck: ', '', msg)[:140]
    rows.append([cls] + f[1:6] + [note])
from collections import Counter
hdr = '''# compiler_optimize.tl -seq-ref residue on main 9a1c92f70 (after batch 3, #9129), reclassified
# 2026-10-20 by the batch-4 flip-and-revert runs (every open site flipped to -seq-borrow,
# with value/type copies at the boundary; a second run also named elided lifetimes).
''' + '\n'.join('# ' + l for l in __doc__.split('classes', 1)[1].strip('\n').split('\n')) + '''
# class\tsite\tfunction\taccessor\tkind\tin-loop\tnote
'''
with open(out, 'w') as f:
    f.write(hdr)
    for r in rows:
        f.write('\t'.join(r) + '\n')
print(len(rows), Counter(r[0] for r in rows).most_common())
