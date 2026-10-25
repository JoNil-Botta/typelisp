"""prepass.view_args(root, files, is_free, form_name, callee, param): for every call of callee in
files whose argument at param's position is a view of a plain place, `(...-shared-view x)` or
`(owned_view.compiler-owned-reference-shared-view x)`, replace the argument with `x` (the
parameter now takes (& T), so the place auto-borrows). Only calls inside free top-level forms are
rewritten. Returns the edits as dicts {rel, line, arg, rep}."""
import re
import sys

sys.path.insert(0, "/tmp/claude-1000/-home-jonathan--herdr-worktrees-typelisp-beauty/"
                   "13093798-d60a-4806-9509-5dce90daa97b/scratchpad/borrows")
import sx  # noqa: E402

PLACE = re.compile(r"[A-Za-z0-9_.?!*-]+")
# Identity views only: the place itself has the view's type (a box or element view does not).
VIEW = re.compile(r"\((?:[a-z_]+\.)?(?:[a-z0-9-]*global-shared-view|compiler-owned-shared-view"
                  r"|compiler-owned-reference-shared-view|ast-place-shared-view"
                  r"|compiler-diagnostic-place-shared-view)(\s+)([A-Za-z0-9_.?!*-]+)\)")


def view_rep(arg):
    """`(...-shared-view x)` -> `x`, keeping any line break before x so line numbers hold."""
    m = VIEW.fullmatch(arg)
    if not m:
        return None
    ws = m.group(1)
    return (ws[ws.index("\n"):] if "\n" in ws else "") + m.group(2)


def param_index(root, files, callee, param):
    for rel in files:
        text = open(f"{root}/{rel}").read()
        m = re.search(r"^\(define \(" + re.escape(callee) + r"(?=[\s)])", text, re.M)
        if not m:
            continue
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
        names = re.findall(r"\[([^\s\[\]]+) : ", text[i:j + 1])
        return names.index(param) if param in names else None
    return None


def view_args(root, files, is_free, form_name, callee, param):
    idx = param_index(root, files, callee, param)
    if idx is None:
        return []
    edits = []
    for rel in files:
        path = f"{root}/{rel}"
        text = open(path).read()
        if callee not in text:
            continue
        found = []

        def walk(n):
            if n[0] == 'P':
                if n[4] is not None:
                    walk(n[4])
                return
            if n[0] not in ('L', 'V'):
                return
            kids = n[3]
            if n[0] == 'L' and kids and kids[0][0] == 'A' and kids[0][3].rsplit('.', 1)[-1] == callee \
                    and len(kids) > 1 + idx:
                a = kids[1 + idx]
                if a[0] == 'L' and len(a[3]) == 2 and a[3][0][0] == 'A' and a[3][1][0] == 'A' \
                        and a[3][0][3].endswith('-shared-view') and PLACE.fullmatch(a[3][1][3]):  # noqa
                    rep = view_rep(text[a[1]:a[2]])
                    if rep is not None:
                        found.append((a[1], a[2], rep))
            for c in kids:
                walk(c)

        for f in sx.parse(text):
            if f[0] != 'L':
                continue
            kids = f[3]
            name = "?"
            if len(kids) > 1:
                k1 = kids[1]
                if k1[0] == 'L' and k1[3] and k1[3][0][0] == 'A':
                    name = k1[3][0][3]
                elif k1[0] == 'A':
                    name = k1[3]
            if not is_free(rel, name) and not getattr(is_free, "line_level", False):
                continue
            mark = len(found)
            walk(f)
            if getattr(is_free, "line_level", False) and not is_free(rel, name):
                kept = []
                for s0, e0, rep0 in found[mark:]:
                    ln0 = text.count("\n", 0, s0) + 1
                    if is_free(rel, name, ln0):
                        kept.append((s0, e0, rep0))
                found[mark:] = kept
        if not found:
            continue
        for s, e, rep in sorted(found, reverse=True):
            arg = text[s:e]
            line = text.count("\n", 0, s) + 1
            col = s - (text.rfind("\n", 0, s) + 1)
            text = text[:s] + rep + text[e:]
            edits.append({"rel": rel, "line": line, "col": col, "arg": arg, "rep": rep})
        open(path, "w").write(text)
    return edits
