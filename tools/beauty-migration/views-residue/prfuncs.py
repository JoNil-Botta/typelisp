#!/usr/bin/env python3
"""usage: prfuncs.py <pr>...: for each fetched pr/<n>, list the top-level forms (by name) in my residue
files that the PR changes (old side = merge-base with origin/main). Writes
target/exp/residue/funcs-<n>.txt as "file\tname" lines."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
FILES = ["src/compiler_backend.tl", "src/compiler_regalloc.tl", "src/compiler_ir_types.tl",
         "src/compiler_lower.tl", "src/compiler_liveness.tl"]
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
FORM = re.compile(r"^\((\S+)\s+\(?([^\s()\[\]]+)")


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True, check=True).stdout


def form_index(text):
    """per line (1-based) -> name of the enclosing top-level form."""
    names = [None]
    cur = None
    for line in text.split("\n"):
        if line.startswith("("):
            m = FORM.match(line)
            cur = (m.group(1) + " " + m.group(2)) if m else line[:40]
        names.append(cur)
    return names


def main():
    for p in sys.argv[1:]:
        mb = git("merge-base", "origin/main", f"pr/{p}").strip()
        out = set()
        for f in FILES:
            try:
                text = git("show", f"{mb}:{f}")
            except subprocess.CalledProcessError:
                continue
            names = form_index(text)
            diff = git("diff", "-U0", mb, f"pr/{p}", "--", f)
            for line in diff.split("\n"):
                m = HUNK.match(line)
                if not m:
                    continue
                start = int(m.group(1))
                count = int(m.group(2)) if m.group(2) is not None else 1
                lo = start if count > 0 else start
                hi = start + max(count, 1) - 1
                for ln in range(max(lo, 1), min(hi, len(names) - 1) + 1):
                    if names[ln]:
                        out.add((f, names[ln]))
        with open(f"{ROOT}/target/exp/residue/funcs-{p}.txt", "w") as fh:
            for f, n in sorted(out):
                fh.write(f"{f}\t{n}\n")
        print(f"#{p} forms={len(out)}")


main()
