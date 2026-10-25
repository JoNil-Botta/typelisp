#!/usr/bin/env python3
"""sigflip.py IN.tl OUT.tl SIGS_FILE: for each "FUNC PARAM" line, change the
parameter `[PARAM : T]` of FUNC's define to `[PARAM : (& PARAM T)]` and adjust:

  in FUNC's body       (& PARAM) and (compiler-opt-global-shared-view PARAM)
                       become PARAM;
  at every call site   the argument in PARAM's position, when it is
                       (owned_view.compiler-owned-reference-shared-view X) or
                       (compiler-opt-global-shared-view X) for a bare name X,
                       becomes X, and (…-seq-ref A B) becomes (…-seq-borrow A B).

Newlines are preserved (replacements are padded with spaces)."""
import re
import sys

src = open(sys.argv[1]).read()
sigs = [l.split() for l in open(sys.argv[3]) if l.strip()]
starts = [m.start() for m in re.finditer(r'^\(', src, re.M)] + [len(src)]
spans = {}
for a, b in zip(starts, starts[1:]):
    m = re.match(r'\(define\s+\(([^\s()\[\]]+)', src[a:a + 300])
    if m:
        spans[m.group(1)] = (a, b)


def form_end(i):
    depth = 0
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


def atom_end(i):
    m = re.match(r'[^\s()\[\]]+', src[i:])
    return i + (m.end() if m else 1)


def args_of(call_start):
    """(start, end) of each argument of the call form at call_start."""
    i = call_start + 1
    i = atom_end(i)  # callee
    end = form_end(call_start) - 1
    out = []
    while i < end:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        if c == ';':
            i = src.find('\n', i)
            continue
        j = form_end(i) if c in '([' else (atom_end(i) if c != '"' else form_end_str(i))
        out.append((i, j))
        i = j
    return out


def form_end_str(i):
    i += 1
    while i < len(src) and src[i] != '"':
        i += 2 if src[i] == '\\' else 1
    return i + 1


def param_index(fn, p):
    a, b = spans[fn]
    lst = src.find('(', a + 1)  # the `(fn [p : T] ...)` list
    lst_end = form_end(lst)
    params = []
    i = atom_end(lst + 1)
    while i < lst_end - 1:
        if src[i] == '[':
            j = form_end(i)
            mm = re.match(r'\[\s*([^\s:\[\]]+)', src[i:j])
            params.append(mm.group(1) if mm else '?')
            i = j
        else:
            i += 1
    return params.index(p) if p in params else -1


edits = []
UNWRAP = re.compile(r'\((?:owned_view\.compiler-owned-reference-shared-view|compiler-opt-global-shared-view)\s+([^\s()\[\]]+)\)$')
SEQREF = re.compile(r'(\((?:ir\.)?compiler-ir-[a-z-]+?)-seq-ref\b')
for fn, p in sigs:
    if fn not in spans:
        print('no define', fn)
        continue
    a, b = spans[fn]
    body = src[a:b]
    m = re.search(r'\[' + re.escape(p) + r'\s*:\s*((?:ir\.|ast\.)?[A-Za-z][\w.-]*)\]', body)
    if not m:
        print('param not by-value', fn, p)
        continue
    k = param_index(fn, p)
    edits.append((a + m.start(), a + m.end(), '[%s : (& %s %s)]' % (p, p, m.group(1))))
    head_end = a + m.end()
    seg = src[head_end:b]
    for pat in (r'\(&\s+' + re.escape(p) + r'\)', r'\(compiler-opt-global-shared-view\s+' + re.escape(p) + r'\)'):
        for mm in re.finditer(pat, seg):
            s0, e0 = head_end + mm.start(), head_end + mm.end()
            edits.append((s0, e0, p + ' ' * ((e0 - s0) - len(p))))
    if k < 0:
        continue
    for cm in re.finditer(r'\((?:opt\.)?' + re.escape(fn) + r'(?=[\s)])', src):
        if a <= cm.start() < a + 20:
            continue
        args = args_of(cm.start())
        if k >= len(args):
            continue
        s0, e0 = args[k]
        text = src[s0:e0]
        u = UNWRAP.match(text)
        if u:
            rep = u.group(1)
            edits.append((s0, e0, rep + ' ' * ((e0 - s0) - len(rep))))
            continue
        sm = SEQREF.match(text)
        if sm:
            edits.append((s0 + sm.start(1), s0 + sm.end(0), sm.group(1) + '-seq-borrow'))
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
print('sig edits', len(edits))
