#!/usr/bin/env python3
"""readonly.py: which by-value parameters in src/ and stdlib/ are read-only (never moved, stored,
returned, rebound, mutated, or passed by value to a parameter that is not itself read-only), as a
greatest fixed point over the call graph; then the flip yield against census.py's sites.tsv.

A use of parameter p in the body is one of:
  read     p.field, (& p), operand of a view `(X-shared-view p ...)` whose result is only
           passed on (see below), matched `(match p ...)`, or an argument to a parameter that is
           already a reference
  pass     argument i of a call to a function defined in src/stdlib: read-only iff that callee
           parameter is a reference or read-only itself
  view     inside a view call: the copy's sink decides (pass to callee param / let / match / ...)
  bad      returned, stored (constructor, set!), let-bound, mutated, rebound, or passed to an
           unknown callee
Outputs target/exp/zero/readonly.json and summary tables."""
import collections
import json
import re
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero")
import sx  # noqa: E402
import census_lib as C  # noqa: E402

ROOT = C.ROOT
OUT = ROOT + "/target/exp/zero/"
COPY_TYPES = {"i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "bool", "f64", "f32", "char", "unit",
              "usize", "isize"}
# callees that only read their aggregate arguments (builtins / ops)
READ_BUILTINS = {"=", "!=", "<", ">", "<=", ">=", "array-length", "array-ref", "length", "string-length",
                 "__tl_array-data", "type-size", "not"}


def copy_type(ty):
    if ty is None:
        return True
    ty = ty.strip()
    if ty in COPY_TYPES:
        return True
    if ty.startswith("(&") or ty.startswith("(Ptr") or ty.startswith("(MutPtr") or ty.startswith("(Array"):
        return True
    return False


texts, parsed, defs = C.load()
MACROS = set()
for _rel, _forms in parsed.items():
    for _f in _forms:
        if _f[0] == 'L' and _f[3] and _f[3][0][0] == 'A' and _f[3][0][3] == 'defmacro' and len(_f[3]) > 1 \
                and _f[3][1][0] == 'L' and _f[3][1][3] and _f[3][1][3][0][0] == 'A':
            MACROS.add(_f[3][1][3][0][3])
WRITE_LIKE = re.compile(r"(push|set!|write|store|install|box|initialize|emit|append|put|insert|add|cell)")


def macro_reads(b):
    """a macro or `__tl_` builtin that only reads its operands (name-based)."""
    if b in ("str-cat", "clone"):
        return True
    if (b in MACROS or b.startswith("__tl")) and not WRITE_LIKE.search(b):
        return True
    return False
# candidate parameters: (fname, index) for unique definitions
uniq = {n: v[0] for n, v in defs.items() if len(v) == 1}
cand = {}
for name, (rel, params) in uniq.items():
    for i, (p, ty) in enumerate(params):
        if p is None or copy_type(ty):
            continue
        cand[(name, i)] = {"rel": rel, "param": p, "type": ty, "uses": []}

# collect uses per candidate parameter
forms_by_name = {}
for rel, forms in parsed.items():
    for f in forms:
        if f[0] == 'L' and f[3] and f[3][0][0] == 'A' and f[3][0][3] == 'define' and len(f[3]) > 1 \
                and f[3][1][0] == 'L' and f[3][1][3] and f[3][1][3][0][0] == 'A':
            forms_by_name.setdefault(f[3][1][3][0][3], []).append((rel, f))


def head_of(n):
    if n is not None and n[0] == 'L' and n[3] and n[3][0][0] == 'A':
        return n[3][0][3]
    return None


def analyze(name, rel, f, params):
    t = texts[rel]
    kids = f[3]
    body_start = 2
    if len(kids) > 3 and kids[2][0] == 'A' and kids[2][3] == ':':
        body_start = 4
    pnames = {p: i for i, (p, ty) in enumerate(params) if p is not None and (name, i) in cand}
    if not pnames:
        return
    uses = {i: [] for i in pnames.values()}
    rebound = set()

    def sink_of(parent, gparent, idx, tail):
        """what a value at (parent, idx) feeds."""
        if tail:
            return ("bad", "return")
        if parent is None:
            return ("bad", "toplevel")
        if parent[0] == 'V':
            gh = head_of(gparent)
            if gh == "let":
                return ("bad", "let")
            return ("bad", "arm")  # value of a non-tail match/cond arm
        ph = head_of(parent)
        if ph is None:
            return ("bad", "other")
        if ph == "match" and idx == 1:
            return ("read", "match")
        if ph in ("&", "&mut"):
            return ("read", "borrow") if ph == "&" else ("bad", "mutborrow")
        if ph == "set!":
            return ("bad", "store" if idx == 2 else "mutate")
        if ph in C.SPECIAL:
            if ph in ("if", "when", "unless", "cond", "and", "or", "not") :
                return ("read", "test")
            return ("bad", "special:" + ph)
        if C.is_ctor(ph):
            return ("bad", "store")
        b = C.base(ph)
        if b in READ_BUILTINS or (b not in uniq and macro_reads(b)):
            return ("read", "builtin")
        if b in uniq:
            return ("pass", (b, idx - 1))
        if b in defs:
            return ("bad", "ambiguous-callee")
        return ("bad", "unknown-callee:" + b)

    def walk(n, parent, gparent, idx, tail):
        if n[0] == 'P':
            if n[4] is not None:
                # postfix field read `(expr).k` or quote: a field read of a param is a read
                walk(n[4], n, parent, 0, False)
            return
        if n[0] == 'A':
            txt = n[3]
            root = txt.split(".")[0]
            if root in pnames and root not in rebound:
                i = pnames[root]
                if txt != root:
                    # field path p.a.b: a read of a field (moving a non-Copy field out is caught later)
                    if head_of(parent) == "set!" and idx == 1:
                        uses[i].append(("bad", "mutate-field"))
                    else:
                        uses[i].append(("read", "field"))
                    return
                if parent is not None and parent[0] == 'L' and head_of(parent) is not None \
                        and C.base(head_of(parent)).endswith("-shared-view") and idx == 1:
                    # view of p: the copy flows to the view's own sink
                    s = view_sink.get(id(parent))
                    uses[i].append(s if s else ("bad", "view-unknown"))
                    return
                uses[i].append(sink_of(parent, gparent, idx, tail))
            return
        if n[0] not in ('L', 'V'):
            return
        k = n[3]
        h = head_of(n)
        # rebinding of a parameter name in let / match / lambda / for: stop tracking it (conservative)
        if h == "let":
            for c in k[1:-1]:
                if c[0] == 'V' and c[3] and c[3][0][0] == 'A' and c[3][0][3] in pnames:
                    rebound.add(c[3][0][3])
        if n[0] == 'V' and head_of(parent) == "match" and idx >= 2 and k:
            pat = t[k[0][1]:k[0][2]]
            for p in pnames:
                if re.search(r"(?<![A-Za-z0-9_?!*.-])" + re.escape(p) + r"(?![A-Za-z0-9_?!*-])", pat):
                    rebound.add(p)
        if h is not None and C.base(h).endswith("-shared-view") and len(k) >= 2:
            view_sink[id(n)] = sink_of(parent, gparent, idx, tail)
        for i, c in enumerate(k):
            if n[0] == 'L' and i == 0 and c[0] == 'A':
                continue
            ctail = False
            if tail:
                if h in ("begin", "unsafe", "when", "unless", "cfg", "let") and i == len(k) - 1:
                    ctail = True
                elif h == "if" and i in (2, 3):
                    ctail = True
                elif n[0] == 'V' and head_of(parent) in ("match", "cond") and i == len(k) - 1:
                    ctail = True
                elif h in ("match", "cond") and c[0] == 'V':
                    ctail = True
            walk(c, n, parent, i, ctail)

    view_sink = {}
    for c in kids[body_start:]:
        walk(c, f, None, kids.index(c), c is kids[-1])
    for p, i in pnames.items():
        u = uses[i]
        if p in rebound:
            u = u + [("bad", "rebound")]
        cand[(name, i)]["uses"] = u


for name, (rel, params) in uniq.items():
    for rel2, f in forms_by_name.get(name, []):
        analyze(name, rel2, f, params)

# greatest fixed point
ro = {k: True for k in cand}
reason = {}
for k, v in cand.items():
    for kind, what in v["uses"]:
        if kind == "bad":
            ro[k] = False
            reason[k] = what
            break
changed = True
rounds = 0
while changed:
    changed = False
    rounds += 1
    for k, v in cand.items():
        if not ro[k]:
            continue
        for kind, what in v["uses"]:
            if kind != "pass":
                continue
            callee, j = what
            cp = uniq[callee][1]
            if j < 0 or j >= len(cp):
                ro[k] = False
                reason[k] = "arity"
                break
            ty = cp[j][1]
            if ty is not None and ty.strip().startswith("(&"):
                continue
            if copy_type(ty):
                # passing an aggregate to a Copy-typed parameter? treat as fine
                continue
            if not ro.get((callee, j), False):
                ro[k] = False
                reason[k] = "passes-to:" + callee
                changed = True
                break

json.dump({f"{k[0]}#{k[1]}": {"rel": v["rel"], "param": v["param"], "type": v["type"], "ro": ro[k],
                              "reason": reason.get(k, "")} for k, v in cand.items()},
          open(OUT + "readonly.json", "w"), indent=0)

n_ro = sum(1 for k in cand if ro[k])
print("candidate by-value aggregate parameters:", len(cand), "read-only:", n_ro, "fixed-point rounds:", rounds)
rs = collections.Counter(reason[k].split(":")[0] for k in cand if not ro[k])
print("not read-only, first reason:", rs.most_common(12))

# flip yield against the census sites
sites = [l.rstrip("\n").split("\t") for l in open(OUT + "sites.tsv")][1:]
by_file = collections.defaultdict(lambda: collections.Counter())
flip_params = set()
for r in sites:
    rel, line, fname, helper, arg, atype, sink, callee, aidx = r
    by_file[rel]["views"] += 1
    if sink == "arg-user":
        by_file[rel]["arg-user"] += 1
        key = (callee, int(aidx)) if aidx != "" else None
        if key in cand:
            if ro[key]:
                by_file[rel]["flip"] += 1
                flip_params.add(key)
                if re.fullmatch(r"[A-Za-z0-9_?!*.-]+", arg):
                    by_file[rel]["flip-place"] += 1
            else:
                by_file[rel]["arg-not-ro"] += 1
        elif key and callee in uniq and 0 <= key[1] < len(uniq[callee][1]):
            ty = uniq[callee][1][key[1]][1]
            by_file[rel]["arg-copy-or-ref-param"] += 1
        else:
            by_file[rel]["arg-unresolved"] += 1
tot = collections.Counter()
for rel, c in by_file.items():
    tot.update(c)
print("\nfile\tviews\targ-user\tflippable\tflip-place\targ-not-ro")
for rel, c in sorted(by_file.items(), key=lambda x: -x[1]["views"])[:20]:
    print(f"{rel}\t{c['views']}\t{c['arg-user']}\t{c['flip']}\t{c['flip-place']}\t{c['arg-not-ro']}")
print(f"TOTAL\t{tot['views']}\t{tot['arg-user']}\t{tot['flip']}\t{tot['flip-place']}\t{tot['arg-not-ro']}")
print("parameters to flip (with at least one view site):", len(flip_params))
print("arg sites to callee params that are Copy/ref typed:", tot["arg-copy-or-ref-param"], "unresolved:", tot["arg-unresolved"])
