#!/usr/bin/env python3
"""copytypes.py: structural Copy classification (SPEC 4.7.2) of every defstruct/defenum in src/ and
stdlib/, then the census sites whose copied value has a Copy type (the view is a no-op copy and
can simply go), and the type distribution of the copied values."""
import collections
import re
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero")
import census_lib as C  # noqa: E402

texts, parsed, defs = C.load()
COPY_LEAVES = {"i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "f64", "f32", "bool", "char", "unit",
               "never", "Expr", "ExprList"}
MOVE_LEAVES = {"String", "ByteBuf", "str", "bytes", "Slice", "Box"}
types = {}  # base name -> list of part type strings, or None (cleanup-owning / unknown)
for rel, forms in parsed.items():
    t = texts[rel]
    for f in forms:
        if f[0] != 'L' or not f[3] or f[3][0][0] != 'A' or f[3][0][3] not in ("defstruct", "defenum"):
            continue
        k = f[3]
        if len(k) < 2:
            continue
        nm = k[1][3] if k[1][0] == 'A' else (k[1][3][0][3] if k[1][0] == 'L' and k[1][3] else None)
        if not nm:
            continue
        parts = []
        cleanup = False
        for c in k[2:]:
            if c[0] != 'L' or not c[3]:
                continue
            first = c[3][0]
            if first[0] == 'A' and first[3].startswith(":"):
                if "cleanup" in first[3]:
                    cleanup = True
                continue
            # struct field (name T) or enum variant (Name T...)
            for p in c[3][1:]:
                parts.append(re.sub(r"\s+", " ", t[p[1]:p[2]]))
        types[nm] = None if cleanup else parts

import os
memo = {n: True for n in filter(None, os.environ.get("FORCE_COPY", "").split(","))}
base_copy = None


def is_copy(ty, depth=0):
    ty = ty.strip()
    if depth > 40:
        return False
    if ty in COPY_LEAVES:
        return True
    if ty in MOVE_LEAVES:
        return False
    if ty.startswith("(&mut"):
        return False
    if ty.startswith("(&") or ty.startswith("(Ptr") or ty.startswith("(MutPtr"):
        return True
    if ty.startswith("(__tl_dyn-array") or ty.startswith("(Box") or ty.startswith("(Slice"):
        return False
    m = re.match(r"\((Array|Tuple)\s+(.*)\)$", ty)
    if m:
        inner = m.group(2)
        elems = re.findall(r"\((?:[^()]|\([^()]*\))*\)|[^\s()]+", inner)
        if m.group(1) == "Array":
            elems = elems[:1]
        return all(is_copy(e, depth + 1) for e in elems)
    if ty.startswith("("):
        # a lifetime-applied nominal (Name a b): classify the nominal
        ty = ty[1:].split()[0]
    b = ty.split(".")[-1]
    if b in memo:
        return memo[b]
    if b not in types:
        return False
    memo[b] = False  # cycle guard: MoveOnly
    parts = types[b]
    r = parts is not None and all(is_copy(p, depth + 1) for p in parts)
    memo[b] = r
    return r


copy_names = sorted(n for n in types if is_copy(n))
print("nominal types:", len(types), "structurally Copy:", len(copy_names))
if os.environ.get("FORCE_COPY"):
    import pickle
    prev = set(open(C.ROOT + "/target/exp/zero/copy-base.txt").read().split())
    newly = sorted(set(copy_names) - prev)
    print("newly Copy:", len(newly), newly[:40])
else:
    open(C.ROOT + "/target/exp/zero/copy-base.txt", "w").write("\n".join(copy_names))
R = C.ROOT + "/target/exp/zero/"
sites = [l.rstrip("\n").split("\t") for l in open(R + "sites.tsv")][1:]
cnt = collections.Counter()
by_type = collections.Counter()
copy_rows = []
for r in sites:
    rel, line, fname, helper, arg, atype, sink, callee, aidx = r
    if not atype:
        cnt["unknown-type"] += 1
        continue
    ty = atype.strip()
    if helper == "compiler-owned-reference-shared-view":
        m = re.match(r"\(&\s+(?:[a-z][A-Za-z0-9_-]*\s+)?(.*)\)$", ty)
        if m:
            ty = m.group(1)
    if is_copy(ty):
        cnt["copy-type"] += 1
        by_type[ty] += 1
        copy_rows.append(r + [ty])
    else:
        cnt["move-type"] += 1
print(dict(cnt))
print("Copy-typed copies by type:", by_type.most_common(15))
if not os.environ.get("FORCE_COPY"):
    with open(R + "copy-sites.tsv", "w") as fh:
        for r in copy_rows:
            fh.write("\t".join(r) + "\n")
