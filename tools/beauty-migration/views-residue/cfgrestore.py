#!/usr/bin/env python3
"""cfgrestore.py BASE FILE: in functions of FILE that contain a `(cfg ...)` form, put back every
`(X-shared-view p)` that this branch replaced by a bare `p` where `p` is not passed to a reference
parameter (that is, the replacement is a move the default-cfg check could not prove for every cfg).
Callee parameter types are read from the current src/*.tl definitions."""
import difflib
import glob
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
base, rel = sys.argv[1], sys.argv[2]
TOK = re.compile(r'"(?:[^"\\]|\\.)*"|;[^\n]*|[()\[\]]|[^\s()\[\];"]+')


def toks(text, start=0):
    out = []
    for m in TOK.finditer(text):
        t = m.group(0)
        if t.startswith(";"):
            continue
        out.append((t, start + m.start()))
    return out


def functions(text):
    out = {}
    starts = [m.start() for m in re.finditer(r"^\(", text, re.M)] + [len(text)]
    for a, b in zip(starts, starts[1:]):
        m = re.match(r"\(define \(([^\s)]+)", text[a:])
        if m:
            out[m.group(1)] = (a, b)
    return out


# parameter types of every definition in src/*.tl, by base name
params = {}
for path in glob.glob(ROOT + "/src/*.tl"):
    t = open(path).read()
    for m in re.finditer(r"^\(define \(([^\s)]+)", t, re.M):
        i = t.index("(", m.start() + 1)
        d = 0
        j = i
        while True:
            c = t[j]
            if c in "([":
                d += 1
            elif c in ")]":
                d -= 1
                if d == 0:
                    break
            j += 1
        ps = re.findall(r"\[([^\s\[\]]+) : (\((?:[^()]|\([^()]*\))*\)|[^\s\]]+)\]", t[i:j + 1])
        params.setdefault(m.group(1), []).append([ty for _, ty in ps])

old = subprocess.run(["git", "-C", ROOT, "show", f"{base}:{rel}"], capture_output=True, text=True).stdout
cur = open(f"{ROOT}/{rel}").read()
fo, fc = functions(old), functions(cur)
edits = []
for name, (a, b) in fc.items():
    body = cur[a:b]
    if "(cfg" not in body or name not in fo:
        continue
    oa, ob = fo[name]
    ot = toks(old[oa:ob])
    ct = toks(body, a)
    sm = difflib.SequenceMatcher(a=[t for t, _ in ot], b=[t for t, _ in ct], autojunk=False)
    mapping = {}
    for blk in sm.get_matching_blocks():
        for d in range(blk.size):
            mapping[blk.a + d] = blk.b + d
    ow = [t for t, _ in ot]
    for k in range(len(ow) - 3):
        if ow[k] == "(" and ow[k + 1].endswith("-shared-view") and ow[k + 3] == ")" \
                and k + 2 in mapping and k not in mapping and k + 1 not in mapping and k + 3 not in mapping:
            j = mapping[k + 2]
            tok, off = ct[j]
            if tok == ow[k + 2]:
                edits.append((off, tok, ow[k + 1]))


def enclosing_call(text, off):
    """(head, argument index) of the innermost call containing off."""
    depth = 0
    i = off - 1
    while i >= 0:
        ch = text[i]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                if ch == "[":
                    return None, None
                seg = text[i + 1:off]
                ts = [t for t, _ in toks(seg)]
                # count top-level items before off
                n = 0
                d = 0
                for t in ts:
                    if t in "([":
                        if d == 0:
                            n += 1
                        d += 1
                    elif t in ")]":
                        d -= 1
                    elif d == 0:
                        n += 1
                head = ts[0] if ts else None
                return head, n - 1
            depth -= 1
        i -= 1
    return None, None


restored = 0
for off, tok, view in sorted(edits, reverse=True):
    head, idx = enclosing_call(cur, off)
    keep = False
    if head and idx is not None and idx >= 0:
        base_name = head.rsplit(".", 1)[-1]
        sigs = params.get(base_name, [])
        if len(sigs) == 1 and idx < len(sigs[0]) and sigs[0][idx].startswith("(&"):
            keep = True
    if keep:
        continue
    cur = cur[:off] + "(" + view + " " + tok + ")" + cur[off + len(tok):]
    restored += 1
    line = cur.count("\n", 0, off) + 1
    print(f"restore {rel}:{line} ({view} {tok}) arg {idx} of {head}")
open(f"{ROOT}/{rel}", "w").write(cur)
print("restored", restored, "of", len(edits))
