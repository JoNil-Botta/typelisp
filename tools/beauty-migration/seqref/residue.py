#!/usr/bin/env python3
"""residue.py FILE.tl RECOVERED.tsv OUT.tsv: inventory of the `-seq-ref`
accessor uses left in FILE, one row per site:

  class  site  function  accessor  kind  in-loop  note

kind     what the copy feeds: let (bound by a let), match (a match scrutinee),
         arg (a call argument), other
in-loop  yes when the site sits inside a while/for form of its function
class    carried over by function name from the pre-reboot list where it is known
         (#9094 = the old #8858 class: a let-bound reference rooted in an
         elided-lifetime parameter; consumer/view/now as before), #8901 for the
         ctor_fwd per-block scan, otherwise `open` (not re-classified).
"""
import re
import sys
from collections import Counter

src = open(sys.argv[1]).read()
known = {}
for line in open(sys.argv[2]):
    f = line.rstrip('\n').split('\t')
    if len(f) >= 4 and f[1].startswith(sys.argv[1].split('/')[-2] + '/') or True:
        if len(f) >= 4 and f[1].split(':')[0].endswith(sys.argv[1].split('/')[-1]):
            cls = '#9094' if f[0] == '#8858' else f[0]
            known.setdefault(f[3], cls)

ACC = re.compile(r'\((?:ir\.)?compiler-ir-([a-z-]+?)-seq-ref\b')
# top-level form starts
tops = [m.start() for m in re.finditer(r'^\(', src, re.M)]
line_starts = [0] + [m.end() for m in re.finditer('\n', src)]


def line_of(pos):
    lo, hi = 0, len(line_starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if line_starts[mid] <= pos:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1


def enclosing_stack(start, pos):
    """Heads of the forms open at pos, scanning from start (a top-level '(')."""
    stack = []
    i = start
    n = len(src)
    while i < pos and i < n:
        c = src[i]
        if c == ';':
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
            i += 1
            continue
        if c == '(' or c == '[':
            m = re.match(r'[(\[]\s*([^\s()\[\]]*)', src[i:i + 80])
            stack.append((c, m.group(1) if m else '', i))
        elif c == ')' or c == ']':
            if stack:
                stack.pop()
        i += 1
    return stack


rows = []
for m in ACC.finditer(src):
    pos = m.start()
    if src.rfind('\n', 0, pos) >= 0 and src[src.rfind('\n', 0, pos) + 1:pos].lstrip().startswith(';'):
        continue
    k = 0
    for t in tops:
        if t <= pos:
            k = t
        else:
            break
    head = re.match(r'\((define|defmacro)\s+\(?([^\s()\[\]]+)', src[k:k + 200])
    if not head:
        continue
    if head.group(1) == 'defmacro' and head.group(2).startswith('compiler-ir-'):
        continue
    if head.group(2).endswith('-seq-ref'):
        continue
    func = head.group(2)
    stack = enclosing_stack(k, pos)
    parent = stack[-1] if stack else ('', '', 0)
    if parent[0] == '[':
        kind = 'let'
    elif parent[1] == 'match':
        kind = 'match'
    elif parent[1] and not parent[1].startswith('set!'):
        kind = 'arg'
    else:
        kind = 'other'
    in_loop = 'yes' if any(h in ('while', 'for') for _, h, _ in stack) else 'no'
    if func == 'opt-ctor-fwd-block':
        cls, note = '#8901', 'per-block ctor_fwd scan; body inlines try-site (body-too-big)'
    else:
        cls, note = known.get(func, 'open'), ''
    rows.append((cls, line_of(pos), func, m.group(1), kind, in_loop, note))

with open(sys.argv[3], 'w') as f:
    f.write('# class\tsite\tfunction\taccessor\tkind\tin-loop\tnote\n')
    for r in rows:
        f.write('%s\t%s:%d\t%s\t%s\t%s\t%s\t%s\n' % (r[0], sys.argv[1].split('/')[-1], r[1], r[2], r[3], r[4], r[5], r[6]))
print(len(rows), dict(Counter(r[0] for r in rows)), dict(Counter(r[4] for r in rows)),
      'in-loop', sum(1 for r in rows if r[5] == 'yes'))
