#!/usr/bin/env python3
"""revertcallee.py BASE FILE NAME PARAM [NAME PARAM ...]: undo this branch's (& T) conversion of
parameter PARAM of NAME in FILE: restore the parameter type from BASE, and at every call of NAME in
FILE put back the argument BASE had at that position when this branch replaced it by a bare place
(a removed `(X-shared-view p)`) or wrapped it in `(& ...)`."""
import difflib
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
base, rel = sys.argv[1], sys.argv[2]
pairs = list(zip(sys.argv[3::2], sys.argv[4::2]))
TOK = re.compile(r'"(?:[^"\\]|\\.)*"|;[^\n]*|[()\[\]]|[^\s()\[\];"]+')


def toks(text, start=0):
    return [(m.group(0), start + m.start()) for m in TOK.finditer(text) if not m.group(0).startswith(";")]


def functions(text):
    out = {}
    starts = [m.start() for m in re.finditer(r"^\(", text, re.M)] + [len(text)]
    for a, b in zip(starts, starts[1:]):
        m = re.match(r"\(define \(([^\s)]+)", text[a:])
        if m:
            out[m.group(1)] = (a, b)
    return out


def header_params(text, name):
    m = re.search(r"^\(define \(" + re.escape(name) + r"(?=[\s)])", text, re.M)
    i = text.index("(", m.start() + 1)
    d = 0
    j = i
    while True:
        c = text[j]
        if c in "([":
            d += 1
        elif c in ")]":
            d -= 1
            if d == 0:
                break
        j += 1
    return i, j, re.findall(r"\[([^\s\[\]]+) : (\((?:[^()]|\([^()]*\))*\)|[^\s\]]+)\]", text[i:j + 1])


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
    raise ValueError


def call_args(text, start):
    """offsets (start, end) of the arguments of the call whose '(' is at start."""
    i = start + 1
    out = []
    head_done = False
    while True:
        while text[i].isspace():
            i += 1
        if text[i] in ")]":
            return out
        if text[i] == ";":
            while text[i] != "\n":
                i += 1
            continue
        e = expr_end(text, i)
        if head_done:
            out.append((i, e))
        head_done = True
        i = e


old = subprocess.run(["git", "-C", ROOT, "show", f"{base}:{rel}"], capture_output=True, text=True).stdout
cur = open(f"{ROOT}/{rel}").read()
for name, param in pairs:
    _, _, ops = header_params(old, name)
    oldty = dict(ops)[param]
    idx = [p for p, _ in ops].index(param)
    i, j, ps = header_params(cur, name)
    hdr = cur[i:j + 1]
    hdr2 = re.sub(r"(\[" + re.escape(param) + r" : )(\((?:[^()]|\([^()]*\))*\)|[^\s\]]+)\]",
                  lambda m: m.group(1) + oldty + "]", hdr, count=1)
    cur = cur[:i] + hdr2 + cur[j + 1:]
    print("param", name, param, "->", oldty)
    # calls: compare each function's calls of name with BASE's, by order within the function
    fo, fc = functions(old), functions(cur)
    edits = []
    for fname, (a, b) in fc.items():
        if fname not in fo:
            continue
        pat = re.compile(r"\((?:[A-Za-z0-9_]+\.)?" + re.escape(name) + r"(?=[\s)])")
        cs = [m.start() + a for m in pat.finditer(cur[a:b])]
        if not cs:
            continue
        oa, ob = fo[fname]
        os_ = [m.start() + oa for m in pat.finditer(old[oa:ob])]
        if len(os_) != len(cs):
            print("WARN call count differs in", fname, len(os_), len(cs))
            continue
        for oc, cc in zip(os_, cs):
            oargs = call_args(old, oc)
            cargs = call_args(cur, cc)
            if idx >= len(oargs) or idx >= len(cargs):
                continue
            ot = old[oargs[idx][0]:oargs[idx][1]]
            ct = cur[cargs[idx][0]:cargs[idx][1]]
            if re.sub(r"\s+", " ", ot) != re.sub(r"\s+", " ", ct):
                edits.append((cargs[idx][0], cargs[idx][1], ot, fname))
    for s, e, ot, fname in sorted(edits, reverse=True):
        print("  restore in", fname, ":", cur[s:e][:50].replace("\n", " "), "->", ot[:50].replace("\n", " "))
        cur = cur[:s] + ot + cur[e:]
open(f"{ROOT}/{rel}", "w").write(cur)
