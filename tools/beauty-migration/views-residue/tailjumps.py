"""tailjumps.py A.s B.s: per function, tail jumps to other functions (`jmp <global>`) and self calls;
lists functions where B has fewer tail jumps or more self calls than A, and the totals."""
import collections
import re
import sys


def scan(path):
    jumps = collections.Counter()
    calls = collections.Counter()
    selfc = collections.Counter()
    funcs = set()
    cur = None
    for line in open(path):
        if line and not line[0].isspace() and line.rstrip().endswith(":") and not line.startswith("."):
            cur = line.rstrip()[:-1]
            funcs.add(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"\s+jmp (_tl_\S+|tl_\S+)$", line)
        if m:
            jumps[cur] += 1
        m = re.match(r"\s+call (\S+)", line)
        if m:
            calls[cur] += 1
            if m.group(1) == cur:
                selfc[cur] += 1
    return funcs, jumps, calls, selfc


fa, ja, ca, sa = scan(sys.argv[1])
fb, jb, cb, sb = scan(sys.argv[2])
print("tail jumps", sum(ja.values()), "->", sum(jb.values()), "; self calls", sum(sa.values()), "->", sum(sb.values()))
print("functions", len(fa), "->", len(fb))
for f in sorted(fa & fb):
    if jb[f] < ja[f] or sb[f] > sa[f]:
        print(f"{f}\ttail-jumps {ja[f]}->{jb[f]}\tself-calls {sa[f]}->{sb[f]}\tcalls {ca[f]}->{cb[f]}")
