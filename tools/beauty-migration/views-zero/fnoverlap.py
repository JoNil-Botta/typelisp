#!/usr/bin/env python3
"""fnoverlap.py OLD NEW PR FILE: the top-level forms that the change OLD..NEW edits in FILE, and which
of them the PR (refs/pr/<PR>, against its merge-base with origin/main) also edits or deletes."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
old, new, pr, rel = sys.argv[1:5]


def git(*a):
    return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True).stdout


def changed_forms(a, b):
    text = git("show", f"{a}:{rel}").split("\n")
    diff = git("diff", "-U0", a, b, "--", rel)
    lines = set()
    for m in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@", diff, re.M):
        s = int(m.group(1))
        n = int(m.group(2)) if m.group(2) is not None else 1
        lines.update(range(s, s + max(n, 1)))
    names = {}
    for ln in lines:
        i = min(ln, len(text))
        while i > 1 and not text[i - 1].startswith("("):
            i -= 1
        m = re.match(r"\((?:define|defmacro|defstruct|defenum) \(?([^\s()]+)", text[i - 1])
        names.setdefault(m.group(1) if m else f"<line {i}>", []).append(ln)
    return names


mine = changed_forms(old, new)
mb = git("merge-base", "origin/main", f"refs/pr/{pr}").strip()
theirs = changed_forms(mb, f"refs/pr/{pr}")
both = sorted(set(mine) & set(theirs))
print(f"{rel}: {len(mine)} forms changed here, {len(theirs)} by #{pr}, {len(both)} in both")
for n in both:
    print("  ", n, "lines", mine[n][:5])
