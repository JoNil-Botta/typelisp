#!/usr/bin/env python3
"""tcoguard.py BASE.s CAND.s STATE PREFIX: revert the siteLoop sites (STATE) inside functions that
lost a tail jump or gained a self call between BASE.s and CAND.s. PREFIX is the asm symbol prefix of
the module (e.g. _tl_compiler_lower_compiler_lower_)."""
import json
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
base_s, cand_s, state_path, prefix = sys.argv[1:5]
out = subprocess.run(["python3", ROOT + "/target/exp/residue/tailjumps.py", base_s, cand_s],
                     capture_output=True, text=True).stdout
bad = set()
for line in out.splitlines()[2:]:
    sym = line.split("\t")[0]
    if not sym.startswith(prefix):
        continue
    name = sym[len(prefix):]
    name = re.sub(r"_question$", "?", name)
    name = re.sub(r"_bang$", "!", name)
    bad.add(name.replace("_", "-"))
print("functions with lost tail calls:", len(bad))
state = json.load(open(state_path))
by_rel = {}
for s in state["sites"]:
    by_rel.setdefault(s["rel"], []).append(s)
hits = []
for rel, sites in by_rel.items():
    lines = open(f"{ROOT}/{rel}").read().split("\n")
    # enclosing define of each site
    for s in sites:
        i = s["line"]
        while i > 1 and not lines[i - 1].startswith("("):
            i -= 1
        m = re.match(r"\(define \(([^\s)]+)", lines[i - 1])
        if m and m.group(1) in bad:
            hits.append(s)
    for s in sorted([h for h in hits if h["rel"] == rel], key=lambda s: (s["line"], s["col"]), reverse=True):
        ln = lines[s["line"] - 1]
        c = s["col"]
        if ln[c:c + len(s["rep"])] != s["rep"]:
            # the re-borrow pass may have turned (& p) into p
            alt = s["rep"][3:-1] if s["rep"].startswith("(& ") else None
            if alt and ln[c:c + len(alt)] == alt:
                lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(alt):]
            else:
                print("WARN", s)
                continue
        else:
            lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(s["rep"]):]
        state["sites"].remove(s)
        state["reverted"].append(s)
    open(f"{ROOT}/{rel}", "w").write("\n".join(lines))
json.dump(state, open(state_path, "w"))
print("sites reverted:", len(hits), "remaining:", len(state["sites"]))
