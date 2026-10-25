#!/usr/bin/env python3
"""conflicts.py PR...: line-level overlap between my working-tree diff (vs origin/main) and each
fetched pr/<n> (diff from its merge-base with origin/main). My changed main-side lines are mapped
to merge-base coordinates through the merge-base..origin/main diff; a PR hunk overlapping or
adjacent (+-1 line) to one of mine is reported with the enclosing top-level form."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=True).stdout


def hunks(a, b, f):
    out = []
    for m in HUNK.finditer(git("diff", "-U0", a, b, "--", f) if b else git("diff", "-U0", a, "--", f)):
        os_, oc = int(m.group(1)), int(m.group(2)) if m.group(2) is not None else 1
        ns, nc = int(m.group(3)), int(m.group(4)) if m.group(4) is not None else 1
        out.append((os_, oc, ns, nc))
    return out


def new_to_old(hs, line):
    """map a line of the new side of a diff to the old side."""
    delta = 0
    for os_, oc, ns, nc in hs:
        nstart = ns if nc > 0 else ns + 1
        if line < nstart:
            break
        if nc > 0 and line < ns + nc:
            return os_  # changed by the diff itself: map to the hunk start
        delta = (os_ + oc) - (ns + nc)
    return line + delta


def forms(text):
    names = [None]
    cur = None
    for line in text.split("\n"):
        if line.startswith("("):
            cur = line[:70]
        names.append(cur)
    return names


files = git("diff", "--name-only", "origin/main", "--", "src", "stdlib", "tools", "tests").split()
main_texts = {}
for p in sys.argv[1:]:
    mb = git("merge-base", "origin/main", f"pr/{p}").strip()
    n = 0
    for f in files:
        mine = hunks("origin/main", None, f)
        if not mine:
            continue
        try:
            fwd = hunks(mb, "origin/main", f)
            theirs = hunks(mb, f"pr/{p}", f)
        except subprocess.CalledProcessError:
            continue
        if not theirs:
            continue
        if f not in main_texts:
            main_texts[f] = forms(git("show", f"origin/main:{f}"))
        names = main_texts[f]
        for os_, oc, _, _ in mine:
            lo = os_ if oc > 0 else os_
            hi = os_ + max(oc, 1) - 1
            mlo, mhi = new_to_old(fwd, lo), new_to_old(fwd, hi)
            for tos, toc, _, _ in theirs:
                tlo = tos if toc > 0 else tos
                thi = tos + max(toc, 1) - 1
                if mlo <= thi + 1 and tlo <= mhi + 1:
                    n += 1
                    print(f"#{p}\t{f}:{lo}-{hi}\t(mb {mlo}-{mhi} vs {tlo}-{thi})\t{names[min(lo, len(names) - 1)]}")
                    break
    print(f"#{p}: {n} overlapping hunks", file=sys.stderr)
