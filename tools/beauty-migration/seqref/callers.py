#!/usr/bin/env python3
# callers.py FILE NAME...: the enclosing top-level functions of every call of
# each NAME, with line numbers.
import sys

sys.path.insert(0, '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp/tools')
import sexp  # noqa: E402

path = sys.argv[1]
text = open(path).read()
defs = list(sexp.toplevel_defines(sexp.parse(text)))
want = set(sys.argv[2:])
hits = {w: [] for w in want}
for name, fn in defs:
    for n in sexp.walk(fn):
        h = sexp.head(n)
        if h in want and n is not fn['c'][1]:
            hits[h].append(f'{name}:{text.count(chr(10), 0, n["a"]) + 1}')
for w in sys.argv[2:]:
    print(w, '<-', ' '.join(hits[w]))
