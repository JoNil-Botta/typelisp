#!/usr/bin/env python3
"""wrapLoop.py [MAX]: typecheck src/main.tl; while the first error is a call argument that expects
a reference and gets a value (`expected (& ...), found ...`), wrap that argument in `(& ...)` and
repeat. Stops on any other error and prints it. Logs each wrap to target/exp/residue/wrap.log."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
CHECK = ROOT + "/target/exp/residue/check.sh"
CLOG = ROOT + "/target/exp/residue/wrap-check.log"
MAX = int(sys.argv[1]) if len(sys.argv) > 1 else 200


def expr_end(text, off):
    if text[off] not in "([":
        m = re.match(r"[^\s()\[\]]+", text[off:])
        return off + m.end()
    depth = 0
    i = off
    in_str = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == ";":
            while text[i] != "\n":
                i += 1
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


for rnd in range(1, MAX + 1):
    out = subprocess.run(["sh", CHECK, ROOT, CLOG], capture_output=True, text=True).stdout
    if "check rc=0" in out:
        print("clean after", rnd, "rounds", flush=True)
        sys.exit(0)
    body = open(CLOG, errors="replace").read()
    m = re.search(r"^(error\[[^\]]*\]: (.*))\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M)
    if not m or not re.search(r"argument \d+.*expected \(& .*, found (?!\(&)", m.group(2)):
        print("stop:", body[:2000], flush=True)
        sys.exit(1)
    rel, line, col = m.group(3), int(m.group(4)), int(m.group(5))
    text = open(f"{ROOT}/{rel}").read()
    lines = text.split("\n")
    off = sum(len(l) + 1 for l in lines[: line - 1]) + col - 1
    end = expr_end(text, off)
    arg = text[off:end]
    text = text[:off] + "(& " + arg + ")" + text[end:]
    open(f"{ROOT}/{rel}", "w").write(text)
    with open(ROOT + "/target/exp/residue/wrap.log", "a") as f:
        f.write(f"{rel}:{line}:{col}\t{arg[:80]}\t{m.group(2)[:120]}\n")
    print("round", rnd, "wrap", f"{rel}:{line}", arg[:60], flush=True)
print("max rounds")
sys.exit(1)
