#!/usr/bin/env python3
"""consumers.py FILE.tl REVERTED.tsv: for every callee named in a call-argument
type error of the flip loop, its definition head, size, how many functions it
blocked, and a crude shape verdict: `returns-param` when the parameter itself is
a match-arm result or returned, `builds` when the body constructs an instruction
(CompilerIrInstr. / builder-push / instr-map), otherwise `reads`."""
import re
import sys
from collections import Counter, defaultdict

src = open(sys.argv[1]).read()
starts = [m.start() for m in re.finditer(r'^\(', src, re.M)] + [len(src)]
forms = {}
for a, b in zip(starts, starts[1:]):
    m = re.match(r'\((define|defmacro)\s+\(([^\s()\[\]]+)', src[a:a + 300])
    if m:
        forms[m.group(2)] = src[a:b]
blocked = defaultdict(set)
param_of = {}
for line in open(sys.argv[2]):
    ln, fn, rnd, msg = line.rstrip('\n').split('\t')
    m = re.search(r"call `([^`]+)` argument (\d+)(?: \(parameter `([^`]+)`\))?", msg)
    if m:
        blocked[m.group(1)].add(fn)
        param_of[m.group(1)] = (m.group(2), m.group(3))
for name, fns in sorted(blocked.items(), key=lambda kv: -len(kv[1])):
    short = name.split('.')[-1] if name.startswith('opt.') else name
    body = forms.get(short)
    if body is None:
        print('%-44s blocks %2d  (not in file) arg %s' % (name, len(fns), param_of[name]))
        continue
    head = body.split('\n')[0][:110]
    p = param_of[name][1]
    shape = 'reads'
    if re.search(r'CompilerIrInstr\.|builder-push|instr-map|\(Some ' + (re.escape(p) if p else '@@') + r'\)', body):
        shape = 'builds'
    if p and re.search(r'\[_ ' + re.escape(p) + r'\]|\s' + re.escape(p) + r'\)\)*\s*$', body, re.M):
        shape = 'returns-param'
    print('%-44s blocks %2d  %4d lines  %-13s param %-8s %s' % (name, len(fns), body.count('\n'), shape, p, head))
