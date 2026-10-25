#!/usr/bin/env python3
"""restoreline.py REL LINE...: restore these lines of REL from HEAD (same line count required)."""
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
rel = sys.argv[1]
TREE = __import__("os").environ.get("TREE", ROOT)
lines = open(f"{TREE}/{rel}").read().split("\n")
head = subprocess.run(["git", "-C", ROOT, "show", f"{__import__('os').environ.get('REV', 'HEAD')}:{rel}"], capture_output=True, text=True).stdout.split("\n")
assert len(head) == len(lines)
for a in sys.argv[2:]:
    ln = int(a)
    print(ln, lines[ln - 1].strip(), "->", head[ln - 1].strip())
    lines[ln - 1] = head[ln - 1]
open(f"{TREE}/{rel}", "w").write("\n".join(lines))
