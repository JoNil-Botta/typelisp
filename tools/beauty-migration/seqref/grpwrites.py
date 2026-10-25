#!/usr/bin/env python3
# grpwrites.py FILE SITES.TSV: for each enclosing function of a site, whether
# its body writes IR storage (seq-set!, replace!, block/instr builder set) or
# calls a helper whose name ends in `!` and takes instrs; prints the writes.
import re
import sys

sys.path.insert(0, '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp/tools')
import sexp  # noqa: E402

path, sites = sys.argv[1], sys.argv[2]
text = open(path).read()
defs = dict(sexp.toplevel_defines(sexp.parse(text)))
names = []
for row in open(sites):
    f = row.split('\t')[1]
    if f not in names:
        names.append(f)
W = re.compile(r'seq-set!|replace!|-instr-seq-take!|block-seq-take!|\(set! \(array-ref [a-z-]*\.slots|phi-input-seq-set!')
for n in names:
    fn = defs.get(n)
    if not fn:
        continue
    body = text[fn['a']:fn['b']]
    hits = [m.group(0) for m in W.finditer(body)]
    calls = sorted(set(re.findall(r'\((opt-[a-z0-9-]*!)', body)))
    if hits:
        print(f'WRITES\t{n}\t{" ".join(sorted(set(hits)))}')
    elif calls:
        print(f'calls!\t{n}\t{" ".join(calls)[:200]}')
