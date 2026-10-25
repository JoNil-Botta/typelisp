#!/usr/bin/env python3
"""matchrevert.py TREE STATE REL:LINE...: put the view back at these match-borrow sites (siteLoop
json STATE; the rewrite is `rep`, or `rep` without its `(& ...)` after the re-borrow fix) and move them
to STATE's reverted list."""
import json
import sys

tree, state_path = sys.argv[1], sys.argv[2]
want = set(sys.argv[3:])
state = json.load(open(state_path))
by_rel = {}
for s in list(state["sites"]):
    if f"{s['rel']}:{s['line']}" in want:
        by_rel.setdefault(s["rel"], []).append(s)
for rel, sites in by_rel.items():
    lines = open(f"{tree}/{rel}").read().split("\n")
    for s in sorted(sites, key=lambda s: (s["line"], s["col"]), reverse=True):
        ln = lines[s["line"] - 1]
        c = s["col"]
        rep = s["rep"]
        if ln[c:c + len(rep)] != rep:
            alt = rep[3:-1] if rep.startswith("(& ") else None
            if alt and ln[c:c + len(alt)] == alt:
                rep = alt
            else:
                print("WARN not found", s)
                continue
        lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(rep):]
        state["sites"].remove(s)
        state["reverted"].append(s)
        print("revert", rel, s["line"], s["arg"])
    open(f"{tree}/{rel}", "w").write("\n".join(lines))
json.dump(state, open(state_path, "w"))
