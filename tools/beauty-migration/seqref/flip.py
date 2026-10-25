#!/usr/bin/env python3
"""flip.py ORIG.tl OUT.tl LINES_FILE: switch the `-seq-ref` accessor uses on the
listed lines of ORIG (1-based line numbers, one per line) to `-seq-borrow`, and
write OUT.

For a let-bound site `[name (…-seq-ref …)]` the binding's uses inside its let
form are adjusted to the reference it now holds:
  (compiler-opt-global-shared-view name)  ->  name
  (& name)                                ->  name
A typed binding `[name : T (…-seq-ref …)]` becomes `[name : (& T) …]`.
Line numbers are preserved (edits never add or remove newlines)."""
import re
import sys

src = open(sys.argv[1]).read()
lines = sorted({int(x) for x in open(sys.argv[3]).read().split()})
line_starts = [0]
for m in re.finditer('\n', src):
    line_starts.append(m.end())
ACC = re.compile(r'(\((?:ir\.)?compiler-ir-[a-z-]+?)-seq-ref\b')


def form_end(pos):
    """Index just past the form whose open paren/bracket is at pos."""
    depth = 0
    i = pos
    n = len(src)
    while i < n:
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
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def enclosing_open(pos):
    """Positions of the forms open at pos, innermost last (from the top form)."""
    top = src.rfind('\n(', 0, pos) + 1
    stack = []
    i = top
    while i < pos:
        c = src[i]
        if c == ';':
            j = src.find('\n', i)
            i = pos if j < 0 else j
            continue
        if c == '"':
            i += 1
            while i < pos and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
            i += 1
            continue
        if c in '([':
            stack.append(i)
        elif c in ')]':
            if stack:
                stack.pop()
        i += 1
    return stack


edits = []  # (start, end, replacement)
for ln in lines:
    a = line_starts[ln - 1]
    b = line_starts[ln] if ln < len(line_starts) else len(src)
    for m in ACC.finditer(src, a, b):
        edits.append((m.start(1), m.end(0), m.group(1) + '-seq-borrow'))
        stack = enclosing_open(m.start())
        if not stack:
            continue
        parent = stack[-1]
        if src[parent] != '[':
            continue
        bind = re.match(r'\[\s*([^\s()\[\]]+)(\s*:\s*)?', src[parent:parent + 200])
        if not bind:
            continue
        name = bind.group(1)
        if bind.group(2):
            # drop the annotation: the binding now holds a reference whose
            # lifetime the checker names after the borrowed sequence
            tstart = parent + bind.end()
            tend = form_end(tstart) if src[tstart] in '([' else re.match(r'[^\s()\[\]]+', src[tstart:]).end() + tstart
            astart = parent + bind.start(2)
            edits.append((astart, tend, ''))
        # the let form holding this binding: two levels up ([bindings are direct
        # children of the let)
        let_pos = stack[-2] if len(stack) >= 2 else None
        if let_pos is None:
            continue
        let_end = form_end(let_pos)
        body_from = form_end(parent)
        seg = src[body_from:let_end]
        for pat, rep in ((r'\(compiler-opt-global-shared-view\s+' + re.escape(name) + r'\)', name),
                         (r'\(&\s+' + re.escape(name) + r'\)', name)):
            for mm in re.finditer(pat, seg):
                s0 = body_from + mm.start()
                e0 = body_from + mm.end()
                # pad with spaces so columns and line numbers stay put
                edits.append((s0, e0, rep + ' ' * ((e0 - s0) - len(rep))))

edits.sort()
out = []
last = 0
for s, e, r in edits:
    if s < last:
        continue
    out.append(src[last:s])
    out.append(r)
    last = e
out.append(src[last:])
open(sys.argv[2], 'w').write(''.join(out))
print('flipped lines', len(lines), 'edits', len(edits))
