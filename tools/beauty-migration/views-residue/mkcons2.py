"""mkcons2.py: derive consLoop2.py (configurable files, held prefix, String -> (& str)) from consLoop.py."""
R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue/"
s = open(R + "consLoop.py").read()


def rep(a, b):
    global s
    assert s.count(a) == 1, a
    s = s.replace(a, b)


rep('for p in glob.glob(R + "funcs-*.txt"):',
    'for p in glob.glob(R + os.environ.get("HELD_PREFIX", "funcs") + "-*.txt"):')
rep('''MINE = {"src/compiler_backend.tl", "src/compiler_regalloc.tl", "src/compiler_ir_types.tl",
        "src/compiler_lower.tl", "src/compiler_liveness.tl"}''',
    '''MINE = set(os.environ["MINE_FILES"].split(","))''')
rep('''def def_site(callee):
    base = callee.rsplit(".", 1)[-1]
    hits = []
    for path in sorted(glob.glob(ROOT + "/src/*.tl")):
        rel = path[len(ROOT) + 1:]
        for i, line in enumerate(open(path), 1):
            if line.startswith("(define (" + base) and re.match(r"\\(define \\(" + re.escape(base) + r"[\\s)]", line):
                hits.append((rel, i))
    return hits[0] if len(hits) == 1 else None''',
    '''def def_site(callee):
    base = callee.rsplit(".", 1)[-1]
    out = subprocess.run(["grep", "-nE", "^\\\\(define \\\\(" + re.escape(base) + "( |$|\\\\))"]
                         + sorted(glob.glob(ROOT + "/src/*.tl")), capture_output=True, text=True).stdout
    hits = []
    for line in out.splitlines():
        path, ln, _ = line.split(":", 2)
        hits.append((path[len(ROOT) + 1:], int(ln)))
    return hits[0] if len(hits) == 1 else None''')
rep('''    out = run(["python3", R + "convCallee.py", base, param])
    if out.startswith("ERR"):
        if "already a reference" not in out:
            state["failed"][key] = out
        return False
    state["converted"][key] = {"base": base, "param": param, "parent": parent, "def": f"{rel}:{ln}"}''',
    '''    oldty = param_type(rel, base, param)
    if oldty is None or oldty.startswith("(&"):
        return False
    newty = "(& str)" if oldty == "String" else "(& " + oldty + ")"
    out = run(["python3", R + "convCallee2.py", rel, base, param, newty])
    if out.startswith("ERR"):
        state["failed"][key] = out
        return False
    state["converted"][key] = {"base": base, "param": param, "parent": parent, "def": f"{rel}:{ln}",
                               "old": oldty, "new": newty}''')
rep('''        run(["python3", R + "convCallee.py", base, info["param"], "--revert"])''',
    '''        run(["python3", R + "convCallee2.py", info["def"].rsplit(":", 1)[0], base, info["param"], info["old"]])''')
rep('''def conv_bases():''', '''def param_type(rel, base, param):
    text = open(f"{ROOT}/{rel}").read()
    m = re.search(r"^\\(define \\(" + re.escape(base) + r"(?=[\\s)])", text, re.M)
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
    pm = re.search(r"\\[" + re.escape(param) + r" : (\\((?:[^()]|\\([^()]*\\))*\\)|[^\\s\\]]+)\\]", text[i:j + 1])
    return pm.group(1) if pm else None


def conv_bases():''')
open(R + "consLoop2.py", "w").write(s)
print("ok")
