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
NO_CONVERT = {"compiler-ir-instr-scalar-fact"} | set(filter(None, os.environ.get("NO_CONVERT", "").split(",")))
CHECK_ROOTS = [r for r in os.environ.get("CHECK_ROOTS", "src/main.tl").split(",") if r]

cands_path, state_path = sys.argv[1], sys.argv[2]
held = set()
for p in glob.glob(R + os.environ.get("HELD_PREFIX", "funcs") + "-*.txt"):
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


MINE = set(os.environ["MINE_FILES"].split(","))


HELD_LINES = {}
if os.environ.get("HELD_LINES"):
    for f_, rs in json.load(open(os.environ["HELD_LINES"])).items():
        HELD_LINES[f_] = sorted((lo, hi) for lo, hi, _ in rs)


def line_free(rel, line, last=None):
    """True when no open PR changes lines line..last (default: just line) of rel."""
    if rel not in MINE:
        return False
    last = line if last is None else last
    return not any(lo <= last and line <= hi for lo, hi in HELD_LINES.get(rel, []))


def is_free(rel, name, line=None):
    if rel not in MINE:
        return False
    if HELD_LINES and line is not None:
        return line_free(rel, line)
    if HELD_LINES and line is None and (rel, name) in held:
        return False
    return (rel, name) not in held


is_free.line_level = bool(HELD_LINES)


def header_free(rel, ln):
    lines = open(f"{ROOT}/{rel}").read().split("\n")
    e = ln
    depth = 0
    for i in range(ln - 1, len(lines)):
        depth += lines[i].count("(") + lines[i].count("[") - lines[i].count(")") - lines[i].count("]")
        e = i + 1
        if "]) :" in lines[i] or ") :" in lines[i]:
            break
    return line_free(rel, ln, e)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def def_site(callee):
    base = callee.rsplit(".", 1)[-1]
    out = subprocess.run(["grep", "-nE", "^\\(define \\(" + re.escape(base) + "( |$|\\))"]
                         + sorted(glob.glob(ROOT + "/src/*.tl")), capture_output=True, text=True).stdout
    hits = []
    for line in out.splitlines():
        path, ln, _ = line.split(":", 2)
        hits.append((path[len(ROOT) + 1:], int(ln)))
    return hits[0] if len(hits) == 1 else None


state = json.load(open(state_path)) if os.path.exists(state_path) else {"converted": {}, "failed": {}, "wraps": []}


def param_type(rel, base, param):
    text = open(f"{ROOT}/{rel}").read()
    m = re.search(r"^\(define \(" + re.escape(base) + r"(?=[\s)])", text, re.M)
    if not m:
        return None
    i = text.index("(", m.start() + 1)
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
    pm = re.search(r"\[" + re.escape(param) + r" : (\((?:[^()]|\([^()]*\))*\)|[^\s\]]+)\]", text[i:j + 1])
    return pm.group(1) if pm else None


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
    if not (is_free(rel, base) or (HELD_LINES and header_free(rel, ln))):
        state["failed"][base] = "held or skipped file"
        return False
    oldty = param_type(rel, base, param)
    if oldty is None or oldty.startswith("(&"):
        return False
    newty = "(& str)" if oldty == "String" else "(& " + oldty + ")"
    out = run(["python3", R + "convCallee2.py", rel, base, param, newty])
    if out.startswith("ERR"):
        state["failed"][key] = out
        return False
    state["converted"][key] = {"base": base, "param": param, "parent": parent, "def": f"{rel}:{ln}",
                               "old": oldty, "new": newty}
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
        run(["python3", R + "convCallee2.py", info["def"].rsplit(":", 1)[0], base, info["param"], info["old"]])
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
            rep0 = ed["rep"]
            cands = [i for i in range(off, off + len(lines[ed["line"] - 1]) + 1)
                     if text.startswith(rep0, i)
                     and (rep0[0] in "(\n" or text[i - 1] in " ([\n")
                     and (rep0[-1] in ")" or i + len(rep0) >= len(text) or text[i + len(rep0)] in " )]\n")]
            if cands:
                k = min(cands, key=lambda i: abs(i - off - ed["col"]))
        else:
            k = text.find(ed["rep"], off)
        if k < 0 and ed["rep"].startswith("(& ") and ed["rep"][3:-1] == ed["arg"]:
            # a wrap whose inside changed since: strip the wrapper structurally
            line_text = lines[ed["line"] - 1]
            starts = [i for i in range(len(line_text)) if line_text.startswith("(& ", i)]
            if starts:
                i0 = off + min(starts, key=lambda i: abs(i - ed.get("col", 0)))
                e0 = expr_end(text, i0)
                text = text[:i0] + text[i0 + 3:e0 - 1] + text[e0:]
                open(f"{ROOT}/{ed['rel']}", "w").write(text)
                print("undo wrap", ed["rel"], ed["line"], flush=True)
                continue
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


if os.environ.get("REVERT_NAMES"):
    for nm in os.environ["REVERT_NAMES"].split(","):
        revert(nm, "manual: " + os.environ.get("REVERT_WHY", "reverted by hand"))
    json.dump(state, open(state_path, "w"), indent=1)
    sys.exit(0)

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


for rnd in range(1, 3000):
    out = ""
    for root_file in CHECK_ROOTS:
        out = subprocess.run(["sh", CHECK, ROOT, CLOG, root_file], capture_output=True, text=True).stdout
        if "check rc=0" not in out:
            break
    if "check rc=0" in out:
        print("clean after", rnd, "rounds; converted", len(state["converted"]), flush=True)
        break
    body = open(CLOG, errors="replace").read()
    m = None
    for m0 in re.finditer(r"^error\[[^\]]*\]: typecheck: (.*)\n\s+--> ([^:\s]+):(\d+):(\d+)", body, re.M):
        if not (m0.group(3) == "1" and m0.group(4) == "1"):
            m = m0
            break
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
    for rel, line, col in src_locs:
        fname, fs, fe = form_at(rel, line)
        if not open(f"{ROOT}/{rel}").read().split("\n")[fs - 1].startswith("(defmacro"):
            break
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
        if is_free(rel, fname, line):
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
    if msg.startswith("ambiguous variant") and rel == m.group(2):
        text = open(f"{ROOT}/{rel}").read()
        lines = text.split("\n")
        off = sum(len(x) + 1 for x in lines[: line - 1]) + col - 1
        start = off - 1 if text[off - 1] == "(" else off
        g = enclosing_head(text, start)
        if g in conv_bases():
            revert(g, "ambiguous variant argument: " + msg[:60])
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
        if text.startswith(um.group(1), off) and g in conv_bases() and is_free(rel, fname, line) \
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
    # a borrow made by a call to a converted callee outlives a later move: revert that callee
    if "borrowed place" in msg or "remains live" in trace:
        hit = None
        for r2, l2, c2 in src_locs:
            t2 = open(f"{ROOT}/{r2}").read()
            ls2 = t2.split("\n")
            o2 = sum(len(x) + 1 for x in ls2[: l2 - 1]) + c2 - 1
            g2 = enclosing_head(t2, o2)
            if g2 in conv_bases():
                hit = g2
                break
        if hit:
            revert(hit, "borrow outlives a move: " + msg[:80])
            json.dump(state, open(state_path, "w"), indent=1)
            continue
    # inside a macro expansion: revert the latest converted callee called in the enclosing form
    if "in expansion of macro" in trace:
        body_text = "\n".join(lines[fs - 1:fe])
        order = list(state["converted"].values())
        inform = [ci["base"] for ci in order
                  if re.search(r"\((?:[a-z_]+\.)?" + re.escape(ci["base"]) + r"[\s)]", body_text)]
        if inform:
            revert(inform[-1], f"error inside a macro expansion in {fname}: " + msg[:80])
            json.dump(state, open(state_path, "w"), indent=1)
            continue
    print("stop: unhandled error in", rel, line, fname, "|", msg, flush=True)
    print(trace[:1500])
    break
json.dump(state, open(state_path, "w"), indent=1)
