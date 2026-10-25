#!/usr/bin/env python3
"""flipLoop.py STATE [--flip SITES]: the multi-file seq-ref -> seq-borrow check-and-revert loop.

--flip SITES: SITES lists `file:line` entries; every compiler-ir-*-seq-ref on those lines becomes
-seq-borrow, and the switched set is written to STATE (one `file:line` per line).
Then: typecheck src/main.tl; for the first error, revert the switched line that holds it or else
the nearest switched line before it in the same top-level form (macro traces are followed into
switched files), log it to STATE.log, and repeat until clean. Resumable: STATE always holds the
lines still switched."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
CHECK = ROOT + "/target/exp/residue/check.sh"
CLOG = ROOT + "/target/exp/residue/loop-check.log"
REF = re.compile(r"(compiler-ir-[a-z-]+)-seq-ref\b")
BOR = re.compile(r"(compiler-ir-[a-z-]+)-seq-borrow\b")
HAS_BORROW = {"value", "phi-input", "switch-case", "instr", "block", "param", "function", "global",
              "extern", "spmd-private-param"}

state = sys.argv[1]
args = sys.argv[2:]


def read(rel):
    return open(f"{ROOT}/{rel}").read().split("\n")


def write(rel, lines):
    open(f"{ROOT}/{rel}", "w").write("\n".join(lines))


def save(flipped):
    with open(state, "w") as f:
        for rel, ln in sorted(flipped):
            f.write(f"{rel}:{ln}\n")


if args and args[0] == "--flip":
    flipped = set()
    by_file = {}
    for entry in open(args[1]).read().split():
        rel, ln = entry.rsplit(":", 1)
        by_file.setdefault(rel, set()).add(int(ln))
    for rel, lns in by_file.items():
        lines = read(rel)
        for ln in lns:
            def sub(m):
                fam = m.group(1).split("compiler-ir-", 1)[1]
                return m.group(1) + ("-seq-borrow" if fam in HAS_BORROW else "-seq-ref")
            new = REF.sub(sub, lines[ln - 1])
            if new != lines[ln - 1]:
                lines[ln - 1] = new
                flipped.add((rel, ln))
        write(rel, lines)
    save(flipped)
    print("flipped", len(flipped), flush=True)
else:
    flipped = set()
    for entry in open(state).read().split():
        rel, ln = entry.rsplit(":", 1)
        flipped.add((rel, int(ln)))


def form_start(lines, ln):
    for i in range(ln, 0, -1):
        if lines[i - 1].startswith("("):
            return i, lines[i - 1][:80]
    return 1, "?"


rounds = 0
while True:
    rounds += 1
    out = subprocess.run(["sh", CHECK, ROOT, CLOG], capture_output=True, text=True).stdout
    if "check rc=0" in out:
        print("clean after", rounds, "rounds;", len(flipped), "lines switched", flush=True)
        break
    body = open(CLOG, errors="replace").read()
    m = re.search(r"^(error\[[^\]]*\]: .*)\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M)
    if not m:
        print("unparsed error; stop\n" + body[:1500], flush=True)
        break
    msg, efile, eline = m.group(1), m.group(2), int(m.group(3))
    files = {rel for rel, _ in flipped}
    end = body.find("\nerror", m.end())
    trace = body[m.start():end if end > 0 else len(body)]
    alllocs = [(f, int(l)) for f, l in re.findall(r"--> ([^:\s]+):(\d+):\d+", trace)]
    files = {rel for rel, _ in flipped}
    hits = [x for x in alllocs if x in flipped]
    pick = None
    for loc in ([hits[-1]] if hits else []) + alllocs:
        rel, ln0 = loc
        if rel not in files:
            continue
        lines = read(rel)
        fstart, fname = form_start(lines, ln0)
        if fname.startswith("(defmacro (compiler-ir-"):
            continue
        cands = [ln for r, ln in flipped if r == rel and fstart <= ln <= ln0]
        if not cands:
            fend = next((i for i in range(ln0 + 1, len(lines) + 1) if lines[i - 1].startswith("(")),
                        len(lines) + 1)
            after = [ln for r, ln in flipped if r == rel and ln0 < ln < fend]
            if after:
                cands = [min(after)]
        if cands:
            pick = (rel, lines, fname, ln0, cands)
            break
    if pick is None:
        print("no switched site for error:", efile, eline, msg, flush=True)
        print(trace[:1500])
        break
    rel, lines, fname, eline, cands = pick
    site = max(cands)
    lines[site - 1] = BOR.sub(r"\1-seq-ref", lines[site - 1])
    write(rel, lines)
    flipped.discard((rel, site))
    save(flipped)
    with open(state + ".log", "a") as f:
        f.write(f"{rel}:{site}\t{fname}\t{eline}\t{msg}\n")
    print("round", rounds, "revert", f"{rel}:{site}", fname[:60], "|", msg[:100], flush=True)
