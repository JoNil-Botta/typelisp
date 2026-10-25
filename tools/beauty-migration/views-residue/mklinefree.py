"""mklinefree.py: line-level freeness for consLoop2.py and prepass.py (HELD_LINES=heldlines.json)."""
R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue/"


def patch(path, pairs):
    s = open(path).read()
    for a, b in pairs:
        assert s.count(a) == 1, (path, a)
        s = s.replace(a, b)
    open(path, "w").write(s)


patch(R + "consLoop2.py", [
    ('''def is_free(rel, name):
    return rel in MINE and (rel, name) not in held
''', '''HELD_LINES = {}
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
'''),
    ('''    if not is_free(rel, base):
        state["failed"][base] = "held or skipped file"''',
     '''    if not (is_free(rel, base) or (HELD_LINES and header_free(rel, ln))):
        state["failed"][base] = "held or skipped file"'''),
    ('''def run(cmd):''', '''def header_free(rel, ln):
    lines = open(f"{ROOT}/{rel}").read().split("\\n")
    e = ln
    depth = 0
    for i in range(ln - 1, len(lines)):
        depth += lines[i].count("(") + lines[i].count("[") - lines[i].count(")") - lines[i].count("]")
        e = i + 1
        if "]) :" in lines[i] or ") :" in lines[i]:
            break
    return line_free(rel, ln, e)


def run(cmd):'''),
    ('''        if is_free(rel, fname):
''', '''        if is_free(rel, fname, line):
'''),
    ('''and g in conv_bases() and is_free(rel, fname) \\''', '''and g in conv_bases() and is_free(rel, fname, line) \\'''),
])
patch(R + "prepass.py", [
    ('''            if not is_free(rel, name):
                continue
            walk(f)''', '''            if not is_free(rel, name) and not getattr(is_free, "line_level", False):
                continue
            mark = len(found)
            walk(f)
            if getattr(is_free, "line_level", False) and not is_free(rel, name):
                kept = []
                for s0, e0, rep0 in found[mark:]:
                    ln0 = text.count("\\n", 0, s0) + 1
                    if is_free(rel, name, ln0):
                        kept.append((s0, e0, rep0))
                found[mark:] = kept'''),
])
print("ok")
