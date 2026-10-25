#!/usr/bin/env python3
"""w1apply.py: rewrite the W1 sites (w1-sites.tsv). An identity view of a Copy place becomes the place;
a reference view of a (& T) with T Copy becomes (deref r). Each (file, line, helper, arg) key must
occur on its line exactly as many times as the census counted it."""
import collections
import re

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
R = ROOT + "/target/exp/zero/"
rows = [l.split("\t") for l in open(R + "w1-sites.tsv").read().split("\n") if l]
keys = collections.Counter((r[0], int(r[1]), r[3], r[4], r[6]) for r in rows)
by_rel = collections.defaultdict(list)
for k, n in keys.items():
    by_rel[k[0]].append((k, n))
done = 0
for rel, items in by_rel.items():
    path = f"{ROOT}/{rel}"
    lines = open(path).read().split("\n")
    for (rel_, ln, helper, arg, kind), n in items:
        pat = re.compile(r"\((?:[a-z_0-9]+\.)?" + re.escape(helper) + r"\s+" + re.escape(arg) + r"\)")
        text = lines[ln - 1]
        found = pat.findall(text)
        if len(found) != n:
            print("MISMATCH", rel, ln, helper, arg, len(found), n, text.strip())
            continue
        rep = arg if kind == "identity" else f"(deref {arg})"
        lines[ln - 1] = pat.sub(lambda m: rep, text)
        done += n
    open(path, "w").write("\n".join(lines))
print("rewrote", done, "of", len(rows))
