#!/usr/bin/env python3
"""consLoop.py CANDS STATE: convert consumer parameters to (& T), then typecheck and repair.

CANDS: lines `callee<TAB>param` to try. STATE: json with converted/failed callees (resumable).
Loop: typecheck src/main.tl; on the first error
  * inside a converted callee's definition: if it is a by-value call argument to another callee G
    that takes T, convert G as well (chained); otherwise revert the callee (and its chain).
  * at a call argument of a converted callee that expects (& T) and gets a value (a temporary):
    wrap it in (& ...) when the enclosing function is free (not held by an open PR, not in
    compiler_optimize.tl); otherwise revert the callee.
  * anything else: stop and print.
Held forms come from target/exp/residue/funcs-*.txt (merge-base names)."""
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
R = ROOT + "/target/exp/residue/"
CHECK = R + "check.sh"
CLOG = R + "cons-check.log"
SKIP_FILES = {"src/compiler_optimize.tl"}
NO_CONVERT = {"compiler-ir-instr-scalar-fact"}

cands_path, state_path = sys.argv[1], sys.argv[2]
held = set()
for p in glob.glob(R + "funcs-*.txt"):
    for line in open(p):
        f, n = line.rstrip("\n").split("\t")
        held.add((f, n.split(" ", 1)[-1]))

FORM = re.compile(r"^\((\S+)\s+\(?([^\s()\[\]]+)")


def form_at(rel, ln):
    lines = open(f"{ROOT}/{rel}").read().split("\n")
    s = ln
    while s > 1 and not lines[s - 1].startswith("("):
        s -= 1
    m = FORM.match(lines[s - 1])
    name = m.group(2) if m else "?"
    e = ln + 1
    while e <= len(lines) and not lines[e - 1].startswith("("):
        e += 1
    return name, s, e - 1


MINE = {"src/compiler_backend.tl", "src/compiler_regalloc.tl", "src/compiler_ir_types.tl",
        "src/compiler_lower.tl", "src/compiler_liveness.tl"}


def is_free(rel, name):
    return rel in MINE and (rel, name) not in held


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def def_site(callee):
    base = callee.rsplit(".", 1)[-1]
    hits = []
    for path in sorted(glob.glob(ROOT + "/src/*.tl")):
        rel = path[len(ROOT) + 1:]
        for i, line in enumerate(open(path), 1):
            if line.startswith("(define (" + base) and re.match(r"\(define \(" + re.escape(base) + r"[\s)]", line):
                hits.append((rel, i))
    return hits[0] if len(hits) == 1 else None


state = json.load(open(state_path)) if os.path.exists(state_path) else {"converted": {}, "failed": {}, "wraps": []}


def conv_bases():
    return {info["base"] for info in state["converted"].values()}


def convert(callee, param, parent):
    base = callee.rsplit(".", 1)[-1]
    key = base + "#" + param
    if base in NO_CONVERT or key in state["failed"] or key in state["converted"] \
            or state["failed"].get(base, "").startswith(("held", "no unique")):
        return False
    site = def_site(base)
    if site is None:
        state["failed"][base] = "no unique definition"
        return False
    rel, ln = site
    if not is_free(rel, base):
        state["failed"][base] = "held or skipped file"
        return False
    out = run(["python3", R + "convCallee.py", base, param])
    if out.startswith("ERR"):
        if "already a reference" not in out:
            state["failed"][key] = out
        return False
    state["converted"][key] = {"base": base, "param": param, "parent": parent, "def": f"{rel}:{ln}"}
    eds = prepass.view_args(ROOT, sorted(MINE), is_free, lambda r, n: form_at(r, n)[0], base, param)
    for ed in eds:
        ed["g"] = base
        state.setdefault("edits", []).append(ed)
    if eds:
        print("  prepass", base, len(eds), "view args", flush=True)
    print("convert", base, param, "(chain of " + parent + ")" if parent else "", flush=True)
    return True


def revert(base, why):
    keys = [k for k, info in state["converted"].items() if info["base"] == base]
    if not keys:
        return
    for key in keys:
        info = state["converted"].pop(key)
        run(["python3", R + "convCallee.py", base, info["param"], "--revert"])
        if not why.startswith("parent "):
            state["failed"][key] = why
    keep = []
    for ed in state.get("edits", []):
        if ed["g"] != base:
            keep.append(ed)
            continue
        text = open(f"{ROOT}/{ed['rel']}").read()
        lines = text.split("\n")
        off = sum(len(x) + 1 for x in lines[: ed["line"] - 1])
        k = -1
        if "col" in ed:
            cands = [i for i in range(off, off + len(lines[ed["line"] - 1]) + 1)
                     if text.startswith(ed["rep"], i)]
            if cands:
                k = min(cands, key=lambda i: abs(i - off - ed["col"]))
        else:
            k = text.find(ed["rep"], off)
        if k < 0:
            print("WARN cannot undo", ed, flush=True)
            continue
        text = text[:k] + ed["arg"] + text[k + len(ed["rep"]):]
        open(f"{ROOT}/{ed['rel']}", "w").write(text)
        print("undo", ed["rel"], ed["line"], ed["rep"][:40], flush=True)
    state["edits"] = keep
    print("revert", base, "|", why[:120], flush=True)
    for child in sorted({ci["base"] for ci in state["converted"].values() if ci["parent"] == base}):
        revert(child, "parent " + base + " reverted")


if not state.get("initialized", True) or (not state["converted"] and not state["failed"]):
    state["initialized"] = True
    for line in open(cands_path):
        if len(line.split()) == 2 and not line.startswith("("):
            callee, param = line.split()
            convert(callee, param, "")
    json.dump(state, open(state_path, "w"), indent=1)

CALLMSG = re.compile(r"call `([^`]+)` argument (\d+)(?: \(parameter `([^`]+)`\))? type mismatch: expected (.+?), found (.+)$")


def param_name(callee, argno):
    site = def_site(callee)
    if site is None:
        return None
    text = open(f"{ROOT}/{site[0]}").read()
    lines = text.split("\n")
    off = sum(len(x) + 1 for x in lines[: site[1] - 1])
    i = text.index("(", off + 1)
    depth = 0
    j = i
    while True:
        ch = text[j]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                break
        j += 1
    names = re.findall(r"\[([^\s\[\]]+) : ", text[i:j + 1])
    return names[argno - 1] if 0 < argno <= len(names) else None


def enclosing_head(text, off):
    """name at the head of the innermost call enclosing offset off."""
    depth = 0
    i = off - 1
    while i >= 0:
        ch = text[i]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                m = re.match(r"[^\s()\[\]]+", text[i + 1:])
                return m.group(0).rsplit(".", 1)[-1] if m else ""
            depth -= 1
        i -= 1
    return ""


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
    raise ValueError("unbalanced")


for rnd in range(1, 400):
    out = subprocess.run(["sh", CHECK, ROOT, CLOG], capture_output=True, text=True).stdout
    if "check rc=0" in out:
        print("clean after", rnd, "rounds; converted", len(state["converted"]), flush=True)
        break
    body = open(CLOG, errors="replace").read()
    m = re.search(r"^error\[[^\]]*\]: typecheck: (.*)\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M)
    if not m:
        print("unparsed\n" + body[:1500], flush=True)
        break
    msg, rel, line, col = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
    end = body.find("\nerror", m.end())
    trace = body[m.start():end if end > 0 else len(body)]
    locs = [(f, int(a), int(b)) for f, a, b in re.findall(r"--> ([^:\s]+):(\d+):(\d+)", trace)]
    src_locs = [x for x in locs if x[0].startswith("src/")]
    if not src_locs:
        print("no src location\n" + trace[:1500], flush=True)
        break
    rel, line, col = src_locs[0]
    fname, fs, fe = form_at(rel, line)
    cm = CALLMSG.search(msg)
    if fname in conv_bases():
        if cm and cm.group(5).startswith("(&") and not cm.group(4).startswith("(&"):
            g = cm.group(1).rsplit(".", 1)[-1]
            pname = cm.group(3) or (param_name(g, int(cm.group(2))) if g[:1].islower() else None)
            if pname and convert(g, pname, fname):
                json.dump(state, open(state_path, "w"), indent=1)
                continue
        if "borrow requires a local, parameter, or aggregate place" in msg and rel == m.group(2):
            text = open(f"{ROOT}/{rel}").read()
            lines = text.split("\n")
            off = sum(len(x) + 1 for x in lines[: line - 1]) + col - 1
            e = expr_end(text, off)
            arg = text[off:e]
            vm = prepass.view_rep(arg)
            if vm is not None:
                rep = vm
                text = text[:off] + rep + text[e:]
                open(f"{ROOT}/{rel}", "w").write(text)
                state.setdefault("edits", []).append({"rel": rel, "line": line, "g": fname, "arg": arg, "rep": rep})
                print("inbody view", f"{rel}:{line}", arg[:60], "->", rep, "in", fname, flush=True)
                json.dump(state, open(state_path, "w"), indent=1)
                continue
        revert(fname, msg)
        json.dump(state, open(state_path, "w"), indent=1)
        continue
    temp_arg = cm and cm.group(4).startswith("(&") and not cm.group(5).startswith("(&") \
        and cm.group(1).rsplit(".", 1)[-1] in conv_bases()
    temp_place = "borrow requires a local, parameter, or aggregate place" in msg
    if (temp_arg or temp_place) and rel == m.group(2):
        text = open(f"{ROOT}/{rel}").read()
        lines = text.split("\n")
        off = sum(len(x) + 1 for x in lines[: line - 1]) + col - 1
        e = expr_end(text, off)
        arg = text[off:e]
        g = cm.group(1).rsplit(".", 1)[-1] if temp_arg else enclosing_head(text, off)
        if is_free(rel, fname):
            vm = prepass.view_rep(arg)
            if vm is not None:
                rep, kind = vm, "view"
            elif re.match(r"\((?:[a-z_]+\.)?compiler-ir-[a-z-]+-seq-ref\s", arg):
                rep, kind = re.sub(r"-seq-ref(?=\s)", "-seq-borrow", arg, count=1), "flip"
            else:
                rep, kind = "(& " + arg + ")", "wrap"
            text = text[:off] + rep + text[e:]
            open(f"{ROOT}/{rel}", "w").write(text)
            state["wraps"].append(f"{rel}:{line}:{col}\t{kind}\t{g}\t{arg[:60]}")
            state.setdefault("edits", []).append({"rel": rel, "line": line, "g": g, "arg": arg, "rep": rep})
            print(kind, f"{rel}:{line}", arg[:60], "->", rep[:40], "for", g, flush=True)
            json.dump(state, open(state_path, "w"), indent=1)
            continue
        if g in conv_bases():
            revert(g, f"temporary argument in held/skipped {rel}:{line} {fname}")
            json.dump(state, open(state_path, "w"), indent=1)
            continue
    um = re.match(r"unbound name ([A-Z][A-Za-z0-9]*)$", msg)
    if um and rel == m.group(2):
        text = open(f"{ROOT}/{rel}").read()
        lines = text.split("\n")
        off = sum(len(x) + 1 for x in lines[: line - 1]) + col - 1
        start = off
        if text[off - 1] == "(" and text[off - 2:off] != "&(":
            start = off - 1
        g = enclosing_head(text, start)
        if text.startswith(um.group(1), off) and g in conv_bases() and is_free(rel, fname) \
                and not text[:start].rstrip().endswith("(&"):
            if start == off:
                arg = um.group(1)
                rep = "(& (" + arg + "))"
            else:
                arg = text[start:expr_end(text, start)]
                rep = "(& " + arg + ")"
            text = text[:start] + rep + text[start + len(arg):]
            open(f"{ROOT}/{rel}", "w").write(text)
            state.setdefault("edits", []).append({"rel": rel, "line": line, "col": col - 1 - (off - start),
                                                  "g": g, "arg": arg, "rep": rep})
            print("variant", f"{rel}:{line}", arg, "->", rep, "for", g, flush=True)
            json.dump(state, open(state_path, "w"), indent=1)
            continue
        if g in conv_bases():
            revert(g, "bare variant argument in held/skipped " + rel)
            json.dump(state, open(state_path, "w"), indent=1)
            continue
    # attribute to a converted callee called on the error line, if any
    lines = open(f"{ROOT}/{rel}").read().split("\n")
    near = [c for c in sorted(conv_bases()) if re.search(r"\((?:[a-z_]+\.)?" + re.escape(c) + r"[\s)]", lines[line - 1])]
    if near:
        revert(near[0], "error at call site: " + msg)
        json.dump(state, open(state_path, "w"), indent=1)
        continue
    print("stop: unhandled error in", rel, line, fname, "|", msg, flush=True)
    print(trace[:1500])
    break
json.dump(state, open(state_path, "w"), indent=1)
