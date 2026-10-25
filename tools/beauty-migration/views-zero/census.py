#!/usr/bin/env python3
"""census.py: classify every `*-shared-view` call use in src/ and stdlib/ by what its copy feeds.

Sinks:
  arg-user   argument to a function defined in src/ or stdlib/ (callee, index recorded)
  arg-other  argument to a macro, builtin or unresolved callee
  let        value of a let binding
  match      match scrutinee
  store      constructor field, set! value
  return     tail position of the enclosing function body
  borrow     operand of (& ...) / (&mut ...)
  other      anything else (if/cond test, and/or operand, nested special form, ...)
Writes target/exp/zero/sites.tsv (one row per use) and target/exp/zero/defs.json (function
signatures), and prints summary tables."""
import collections
import glob
import json
import re
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero")
import sx  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
OUT = ROOT + "/target/exp/zero/"
FILES = sorted(set(glob.glob(ROOT + "/src/*.tl") + glob.glob(ROOT + "/src/*/*.tl")
                   + glob.glob(ROOT + "/stdlib/*.tl") + glob.glob(ROOT + "/stdlib/*/*.tl")))
SPECIAL = {"if", "let", "begin", "cond", "when", "unless", "and", "or", "not", "match", "&", "&mut",
           "set!", "while", "for", "unsafe", "cast", "try", "deref", "cfg", "lambda", "with",
           "quote", "quasiquote", "+=", "-=", "else", "comptime", "foreach", "loop", "return",
           "ptr-read", "ptr-addr-of", "ptr-cast", "ptr-write!", "ptr-offset", "box", "unbox",
           "tuple", "array", "in-arena", "replace!", "type", "the"}
SIX = {"compiler-owned-shared-view", "tc-global-shared-view", "compiler-owned-reference-shared-view",
       "lower-global-shared-view", "compiler-backend-global-shared-view", "compiler-opt-global-shared-view"}


def base(name):
    return name.rsplit(".", 1)[-1] if "." in name and not name.startswith(".") else name


def is_ctor(name):
    parts = name.split(".")
    return any(p[:1].isupper() for p in parts)


texts = {}
defs = collections.defaultdict(list)   # base name -> [(rel, [(param, type)])]
macros = set()
view_defs = set()
parsed = {}
for path in FILES:
    rel = path[len(ROOT) + 1:]
    t = open(path).read()
    texts[rel] = t
    try:
        forms = sx.parse(t)
    except ValueError as e:
        print("parse error", rel, e, file=sys.stderr)
        continue
    parsed[rel] = forms
    for f in forms:
        if f[0] != 'L' or not f[3] or f[3][0][0] != 'A':
            continue
        h = f[3][0][3]
        if h in ("define", "defmacro") and len(f[3]) > 1 and f[3][1][0] == 'L' and f[3][1][3] \
                and f[3][1][3][0][0] == 'A':
            name = f[3][1][3][0][3]
            if h == "defmacro":
                macros.add(name)
                if name.endswith("-shared-view"):
                    view_defs.add(name)
                continue
            params = []
            for p in f[3][1][3][1:]:
                if p[0] == 'V' and len(p[3]) >= 3 and p[3][0][0] == 'A' and p[3][1][0] == 'A' \
                        and p[3][1][3] == ':':
                    params.append((p[3][0][3], t[p[3][2][1]:p[3][-1][2]]))
                else:
                    params.append((None, None))
            defs[name].append((rel, params))
            if name.endswith("-shared-view"):
                view_defs.add(name)

rows = []


def scan_form(rel, f):
    t = texts[rel]
    kids = f[3]
    h = kids[0][3]
    fname = "?"
    params = {}
    body_start = 1
    if h == "define" and len(kids) > 1 and kids[1][0] == 'L' and kids[1][3] and kids[1][3][0][0] == 'A':
        fname = kids[1][3][0][3]
        for p in kids[1][3][1:]:
            if p[0] == 'V' and len(p[3]) >= 3 and p[3][0][0] == 'A':
                params[p[3][0][3]] = t[p[3][2][1]:p[3][-1][2]]
        body_start = 2
        # skip `: RetType`
        if len(kids) > 3 and kids[2][0] == 'A' and kids[2][3] == ':':
            body_start = 4
    elif h in ("defmacro", "defstruct", "defenum", "import", "extern"):
        return
    elif h == "define":
        # global: (define name : T value)
        fname = kids[1][3] if len(kids) > 1 and kids[1][0] == 'A' else "?"
        body_start = 2
    if fname.endswith("-shared-view"):
        return
    lets = []  # stack of {name: type}

    def var_type(place):
        root = place.split(".")[0]
        if "." in place:
            return None
        for scope in reversed(lets):
            if root in scope:
                return scope[root]
        return params.get(root)

    def walk(n, parent, idx, tail):
        if n[0] == 'P':
            if n[4] is not None:
                walk(n[4], parent, idx, False)
            return
        if n[0] not in ('L', 'V'):
            return
        k = n[3]
        if n[0] == 'L' and len(k) >= 1 and k[0][0] == 'A' and base(k[0][3]).endswith("-shared-view") \
                and base(k[0][3]) not in ("ptr-read",):
            helper = base(k[0][3])
            arg = t[k[1][1]:k[1][2]] if len(k) > 1 else ""
            sink, callee, aidx = classify(parent, idx, tail)
            atype = var_type(arg) if len(k) == 2 and k[1][0] == 'A' else None
            line = t.count("\n", 0, n[1]) + 1
            rows.append((rel, line, fname, helper, re.sub(r"\s+", " ", arg)[:60], re.sub(r"\s+", " ", atype or ""), sink,
                         callee or "", aidx if aidx is not None else ""))
            # nested views inside the argument still count
            for c in k[1:]:
                walk(c, n, k.index(c), False)
            return
        head = k[0][3] if n[0] == 'L' and k and k[0][0] == 'A' else None
        if head == "let":
            scope = {}
            lets.append(scope)
            for i, c in enumerate(k[1:], 1):
                last = i == len(k) - 1
                if c[0] == 'V' and not last:
                    # binding [name : T value] or [name value]
                    ck = c[3]
                    if ck and ck[0][0] == 'A':
                        if len(ck) >= 4 and ck[1][0] == 'A' and ck[1][3] == ':':
                            scope[ck[0][3]] = t[ck[2][1]:ck[2][2]]
                    for j, cc in enumerate(ck):
                        walk(cc, c, j, False)
                else:
                    walk(c, n, i, tail and last)
            lets.pop()
            return
        for i, c in enumerate(k):
            if n[0] == 'L' and i == 0 and c[0] == 'A':
                continue
            ctail = False
            if tail:
                if head in ("begin", "unsafe", "when", "unless", "cfg") and i == len(k) - 1:
                    ctail = True
                elif head == "if" and i in (2, 3):
                    ctail = True
                elif n[0] == 'V' and parent is not None and parent[0] == 'L' and parent[3] \
                        and parent[3][0][0] == 'A' and parent[3][0][3] in ("match", "cond") \
                        and i == len(k) - 1:
                    ctail = True
                elif head in ("match", "cond") and c[0] == 'V':
                    ctail = True
            walk(c, n, i, ctail)

    def classify(parent, idx, tail):
        if parent is None:
            return ("return" if tail else "other"), None, None
        if tail:
            return "return", None, None
        if parent[0] == 'V':
            return "let", None, None   # binding value or arm body handled by tail
        pk = parent[3]
        ph = pk[0][3] if pk and pk[0][0] == 'A' else None
        if ph is None:
            return "other", None, None
        if ph == "match" and idx == 1:
            return "match", None, None
        if ph == "set!" and idx == 2:
            return "store", None, None
        if ph in ("&", "&mut"):
            return "borrow", None, None
        if ph in SPECIAL:
            return "other", None, None
        if is_ctor(ph):
            return "store", None, None
        b = base(ph)
        if b in defs:
            return "arg-user", b, idx - 1
        return "arg-other", b, idx - 1

    for c in kids[body_start:]:
        walk(c, f, kids.index(c), c is kids[-1] and h == "define" and fname != "?")


for rel, forms in parsed.items():
    for f in forms:
        if f[0] == 'L' and f[3] and f[3][0][0] == 'A':
            scan_form(rel, f)

with open(OUT + "sites.tsv", "w") as fh:
    fh.write("file\tline\tfunction\thelper\targ\targ_type\tsink\tcallee\tindex\n")
    for r in rows:
        fh.write("\t".join(str(x) for x in r) + "\n")
json.dump({k: v for k, v in defs.items()}, open(OUT + "defs.json", "w"))

total = len(rows)
print("view uses scanned:", total)
by_sink = collections.Counter(r[6] for r in rows)
helpers = collections.Counter(r[3] for r in rows)
sinks = ["arg-user", "arg-other", "let", "match", "store", "return", "borrow", "other"]
print("\nhelper" + "".join(f"\t{s}" for s in sinks) + "\ttotal")
for h, n in helpers.most_common(10):
    c = collections.Counter(r[6] for r in rows if r[3] == h)
    print(h + "".join(f"\t{c[s]}" for s in sinks) + f"\t{n}")
c = by_sink
print("ALL" + "".join(f"\t{c[s]}" for s in sinks) + f"\t{total}")
