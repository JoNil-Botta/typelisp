#!/usr/bin/env python3
"""moveLoop.py PREFIX STATE FILE...: ownership transfer at view sites.

Every single-line identity view `(X-shared-view place)` in the free `define` forms of FILEs becomes
`place` (the value moves, or the place auto-borrows into a (& T) parameter). Then: typecheck
src/main.tl; for the first error, revert the switched site that the error trace points into (the
"move happened here" location first), else the nearest switched site before the error in the same
top-level form; repeat until clean. STATE (json) keeps the switched sites, so a rerun resumes."""
import bisect
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, "/tmp/claude-1000/-home-jonathan--herdr-worktrees-typelisp-beauty/"
                   "13093798-d60a-4806-9509-5dce90daa97b/scratchpad/borrows")
import sx  # noqa: E402

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
R = ROOT + "/target/exp/zero/"
CHECK = R + "check.sh"
CLOG = R + "move-check.log"
prefix, state_path, files = sys.argv[1], sys.argv[2], sys.argv[3:]
held = set()
for p in glob.glob(f"{R}{prefix}-*.txt"):
    for line in open(p):
        f, n = line.rstrip("\n").split("\t")
        held.add((f, n.split(" ", 1)[-1]))


def form_name(f):
    kids = f[3]
    if len(kids) > 1:
        k1 = kids[1]
        if k1[0] == 'L' and k1[3] and k1[3][0][0] == 'A':
            return k1[3][0][3]
        if k1[0] == 'A':
            return k1[3]
    return "?"


def lines_of(rel):
    return open(f"{ROOT}/{rel}").read().split("\n")


if os.path.exists(state_path):
    state = json.load(open(state_path))
else:
    state = {"sites": [], "reverted": []}
    for rel in files:
        text = open(f"{ROOT}/{rel}").read()
        found = []

        MODE = os.environ.get("MODE", "move")
        REFVIEW = re.compile(r"\((?:[a-z_]+\.)?compiler-owned-reference-shared-view\s+([A-Za-z0-9_?!*-]+)\)")

        def walk(n, parent=None, idx=0):
            if n[0] == 'P':
                if n[4] is not None:
                    walk(n[4], n, 0)
                return
            if n[0] not in ('L', 'V'):
                return
            if n[0] == 'L' and len(n[3]) == 2 and n[3][0][0] == 'A' and n[3][1][0] == 'A':
                arg = text[n[1]:n[2]]
                in_match = (parent is not None and parent[0] == 'L' and parent[3] and parent[3][0][0] == 'A'
                            and parent[3][0][3] == "match" and idx == 1)
                if "\n" not in arg:
                    if MODE == "move" and prepass.view_rep(arg) is not None:
                        found.append((n[1], n[2], arg, prepass.view_rep(arg)))
                        return
                    if MODE == "match-borrow" and in_match:
                        rm = REFVIEW.fullmatch(arg)
                        if rm:
                            found.append((n[1], n[2], arg, rm.group(1)))
                            return
                        vr = prepass.view_rep(arg)
                        if vr is not None and "." not in vr:
                            found.append((n[1], n[2], arg, "(& " + vr + ")"))
                            return
            for i, c in enumerate(n[3]):
                walk(c, n, i)

        HL = json.load(open(os.environ["HELD_LINES"])).get(rel, []) if os.environ.get("HELD_LINES") else None
        starts = [0] + [i + 1 for i, ch in enumerate(text) if ch == "\n"]
        for f in sx.parse(text):
            if f[0] == 'L' and f[3] and f[3][0][0] == 'A' and f[3][0][3] == 'define' \
                    and "(cfg" not in text[f[1]:f[2]] \
                    and (HL is not None or (rel, form_name(f)) not in held):
                mark = len(found)
                walk(f)
                if HL is not None:
                    found[mark:] = [x for x in found[mark:]
                                    if not any(lo <= bisect.bisect_right(starts, x[0]) <= hi for lo, hi, _ in HL)]
        for s, e, arg, rep in sorted(found, reverse=True):
            text = text[:s] + rep + text[e:]
        open(f"{ROOT}/{rel}", "w").write(text)
        # record final positions (line, col) in the rewritten text
        shift = 0
        starts2 = [0] + [i + 1 for i, ch in enumerate(text) if ch == "\n"]
        for s, e, arg, rep in sorted(found):
            ns = s - shift
            line = bisect.bisect_right(starts2, ns)
            col = ns - starts2[line - 1]
            state["sites"].append({"rel": rel, "line": line, "col": col, "arg": arg, "rep": rep})
            shift += len(arg) - len(rep)
    json.dump(state, open(state_path, "w"))
    print("switched", len(state["sites"]), flush=True)


def form_start(lines, ln):
    for i in range(ln, 0, -1):
        if lines[i - 1].startswith("("):
            return i
    return 1


def revert_site(site):
    lines = lines_of(site["rel"])
    ln = lines[site["line"] - 1]
    c = site["col"]
    assert ln[c:c + len(site["rep"])] == site["rep"], (site, ln)
    lines[site["line"] - 1] = ln[:c] + site["arg"] + ln[c + len(site["rep"]):]
    open(f"{ROOT}/{site['rel']}", "w").write("\n".join(lines))
    delta = len(site["arg"]) - len(site["rep"])
    for o in state["sites"]:
        if o is not site and o["rel"] == site["rel"] and o["line"] == site["line"] and o["col"] > c:
            o["col"] += delta
    state["sites"].remove(site)
    state["reverted"].append(site)


rounds = 0
while True:
    rounds += 1
    out = ""
    for root_file in [r for r in os.environ.get("CHECK_ROOTS", "src/main.tl").split(",") if r]:
        out = subprocess.run(["sh", CHECK, ROOT, CLOG, root_file], capture_output=True, text=True).stdout
        if "check rc=0" not in out:
            break
    if "check rc=0" in out:
        print("clean after", rounds, "rounds;", len(state["sites"]), "sites switched,",
              len(state["reverted"]), "reverted", flush=True)
        break
    body = open(CLOG, errors="replace").read()
    blocks = [mm for mm in re.finditer(r"^(error\[[^\]]*\]: .*)\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M)]
    if not blocks:
        print("unparsed\n" + body[:1500], flush=True)
        break
    picks = []
    msg = blocks[0].group(1)
    seen_funcs = set()
    for bi, m in enumerate(blocks):
        end = blocks[bi + 1].start() if bi + 1 < len(blocks) else len(body)
        trace = body[m.start():end]
        locs = [(f, int(a_), int(b_)) for f, a_, b_ in re.findall(r"--> ([^:\s]+):(\d+):(\d+)", trace)]
        here = []
        for mm in re.finditer(r"--> ([^:\s]+):(\d+):(\d+)\n(?:.*\n){1,3}?.*happened here", trace):
            here.append((mm.group(1), int(mm.group(2)), int(mm.group(3))))
        pick = None
        for rel, ln, col in here + locs:
            for s_ in state["sites"]:
                if s_["rel"] == rel and s_["line"] == ln and s_["col"] <= col - 1 < s_["col"] + max(len(s_["rep"]), 1):
                    pick = s_
                    break
            if pick:
                break
        fkey = None
        if pick is None:
            for rel, ln, col in locs:
                if rel not in files:
                    continue
                lines = lines_of(rel)
                fs = form_start(lines, ln)
                fkey = (rel, fs)
                cands = [s_ for s_ in state["sites"] if s_["rel"] == rel and fs <= s_["line"] <= ln]
                if not cands:
                    fe = next((i for i in range(ln + 1, len(lines) + 1) if lines[i - 1].startswith("(")),
                              len(lines) + 1)
                    after = [s_ for s_ in state["sites"] if s_["rel"] == rel and ln < s_["line"] < fe]
                    if after:
                        cands = [min(after, key=lambda s_: (s_["line"], s_["col"]))]
                if cands:
                    pick = max(cands, key=lambda s_: (s_["line"], s_["col"]))
                    break
        if pick is None:
            if bi == 0:
                print("no site for error:", msg, "\n" + trace[:1500], flush=True)
            continue
        # a fallback pick is only trusted for the first error of a function this round
        if fkey is not None:
            if fkey in seen_funcs:
                continue
            seen_funcs.add(fkey)
        if pick not in picks:
            picks.append(pick)
    if not picks:
        break
    for pick in picks:
        revert_site(pick)
    json.dump(state, open(state_path, "w"))
    if rounds % 20 == 0:
        print("round", rounds, "reverted", len(state["reverted"]), "|", msg[:100], flush=True)
