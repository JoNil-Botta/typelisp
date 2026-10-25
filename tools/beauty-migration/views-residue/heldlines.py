#!/usr/bin/env python3
"""heldlines.py BASE FILES PR...: line ranges (in BASE coordinates) that each open PR changes in
FILES (comma-separated), mapped from the PR's merge-base through the merge-base..BASE diff and
widened by 2 lines on each side. Writes target/exp/residue/heldlines.json {file: [[lo, hi, pr]]}."""
import json
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)
base, files, prs = sys.argv[1], sys.argv[2].split(","), sys.argv[3:]


def git(*a):
    return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True).stdout


def hunks(a, b, f):
    out = []
    for m in HUNK.finditer(git("diff", "-U0", a, b, "--", f)):
        os_, oc = int(m.group(1)), int(m.group(2)) if m.group(2) is not None else 1
        ns, nc = int(m.group(3)), int(m.group(4)) if m.group(4) is not None else 1
        out.append((os_, oc, ns, nc))
    return out


def old_to_new(hs, line):
    """map an old-side line to (lo, hi) on the new side."""
    delta = 0
    for os_, oc, ns, nc in hs:
        if oc == 0:
            if line <= os_:
                break
            delta = (ns + nc) - (os_ + oc)
            continue
        if line < os_:
            break
        if line < os_ + oc:
            return ns, ns + max(nc, 1) - 1
        delta = (ns + nc) - (os_ + oc)
    return line + delta, line + delta


out = {f: [] for f in files}
for p in prs:
    mb = git("merge-base", base, f"pr/{p}").strip()
    for f in files:
        fwd = hunks(mb, base, f)
        for os_, oc, _, _ in hunks(mb, f"pr/{p}", f):
            lo = os_ if oc > 0 else os_
            hi = os_ + max(oc, 1) - 1
            a = old_to_new(fwd, lo)[0]
            b = old_to_new(fwd, hi)[1]
            out[f].append([min(a, b) - 2, max(a, b) + 2, p])
json.dump(out, open(f"{ROOT}/target/exp/residue/heldlines.json", "w"))
for f in files:
    print(f, len(out[f]), "ranges")
