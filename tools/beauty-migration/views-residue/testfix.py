#!/usr/bin/env python3
"""testfix.py ROOT.tl: typecheck ROOT.tl; while the first error is a by-value argument to a
parameter that now takes (& T) (a temporary, a bare or applied variant, or a view of a place),
rewrite that argument and repeat. Stops on anything else."""
import re
import subprocess
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
CHECK = ROOT + "/target/exp/residue/check.sh"
CLOG = ROOT + "/target/exp/residue/testfix-check.log"
target = sys.argv[1]


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
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


for rnd in range(1, 300):
    out = subprocess.run(["sh", CHECK, ROOT, CLOG, target], capture_output=True, text=True).stdout
    if "check rc=0" in out:
        print("clean after", rnd, "rounds", flush=True)
        sys.exit(0)
    body = open(CLOG, errors="replace").read()
    m = re.search(r"^error\[[^\]]*\]: typecheck: (.*)\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M)
    if not m:
        print("unparsed\n" + body[:1500])
        sys.exit(1)
    msg, rel, line, col = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
    import json as _json
    import os as _os
    hl = _os.environ.get("HELD_LINES")
    if hl:
        rs = _json.load(open(hl)).get(rel, [])
        hit = [r for r in rs if r[0] <= line <= r[1]]
        if hit:
            print("stop: held line", rel, line, hit[0][2], msg[:140])
            sys.exit(2)
    text = open(f"{ROOT}/{rel}").read()
    lines = text.split("\n")
    off = sum(len(x) + 1 for x in lines[: line - 1]) + col - 1
    rep = None
    if re.match(r"unbound name [A-Z]", msg):
        if text[off - 1] == "(":
            start = off - 1
            arg = text[start:expr_end(text, start)]
            rep = "(& " + arg + ")"
        else:
            start = off
            arg = text[start:expr_end(text, start)]
            rep = "(& (" + arg + "))"
    elif re.search(r"argument \d+.*expected \(& .*, found (?!\(&)", msg) or \
            "borrow requires a local, parameter, or aggregate place" in msg:
        start = off
        arg = text[start:expr_end(text, start)]
        rep = prepass.view_rep(arg) or "(& " + arg + ")"
    if rep is None:
        print("stop:", rel, line, msg)
        print(body[m.start():m.start() + 1500])
        sys.exit(1)
    text = text[:start] + rep + text[start + len(arg):]
    open(f"{ROOT}/{rel}", "w").write(text)
    print("fix", f"{rel}:{line}", arg[:50], "->", rep[:50], flush=True)
print("max rounds")
sys.exit(1)
