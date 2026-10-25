#!/usr/bin/env python3
"""retry.py SITES: flip each listed `file:line` alone (seq-ref -> seq-borrow on that line),
typecheck, keep it when clean, else restore. Prints kept sites."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
CHECK = ROOT + "/target/exp/residue/check.sh"
CLOG = ROOT + "/target/exp/residue/retry-check.log"
FAM = re.compile(r"(compiler-ir-(?:value|phi-input|switch-case|instr|block|param|function|global|extern|spmd-private-param))-seq-ref\b")
kept = 0
for entry in open(sys.argv[1]).read().split():
    rel, ln = entry.rsplit(":", 1)
    ln = int(ln)
    path = f"{ROOT}/{rel}"
    lines = open(path).read().split("\n")
    old = lines[ln - 1]
    new = FAM.sub(r"\1-seq-borrow", old)
    if new == old:
        continue
    lines[ln - 1] = new
    open(path, "w").write("\n".join(lines))
    out = subprocess.run(["sh", CHECK, ROOT, CLOG], capture_output=True, text=True).stdout
    if "check rc=0" in out:
        kept += 1
        print("kept", entry, flush=True)
    else:
        lines[ln - 1] = old
        open(path, "w").write("\n".join(lines))
print("kept", kept, flush=True)
