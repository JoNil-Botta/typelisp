"""census_lib: shared loading for the zero-view research scripts (parse src/ and stdlib/, index
function definitions)."""
import collections
import glob
import os
import pickle
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sx  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
SPECIAL = {"if", "let", "begin", "cond", "when", "unless", "and", "or", "not", "match", "&", "&mut",
           "set!", "while", "for", "unsafe", "cast", "try", "deref", "cfg", "lambda", "with",
           "quote", "quasiquote", "+=", "-=", "else", "comptime", "foreach", "loop", "return",
           "ptr-read", "ptr-addr-of", "ptr-cast", "ptr-write!", "ptr-offset", "box", "unbox",
           "tuple", "array", "in-arena", "replace!", "type", "the"}


def base(name):
    return name.rsplit(".", 1)[-1] if "." in name and not name.startswith(".") else name


def is_ctor(name):
    return any(p[:1].isupper() for p in name.split("."))


def files():
    return sorted(set(glob.glob(ROOT + "/src/*.tl") + glob.glob(ROOT + "/src/*/*.tl")
                      + glob.glob(ROOT + "/stdlib/*.tl") + glob.glob(ROOT + "/stdlib/*/*.tl")))


def load(cache=ROOT + "/target/exp/zero/parse.pickle"):
    stamp = [(p, os.path.getmtime(p)) for p in files()]
    if os.path.exists(cache):
        with open(cache, "rb") as fh:
            data = pickle.load(fh)
        if data["stamp"] == stamp:
            return data["texts"], data["parsed"], data["defs"]
    texts, parsed = {}, {}
    defs = collections.defaultdict(list)
    for path, _ in stamp:
        rel = path[len(ROOT) + 1:]
        t = open(path).read()
        texts[rel] = t
        try:
            forms = sx.parse(t)
        except ValueError:
            continue
        parsed[rel] = forms
        for f in forms:
            if f[0] != 'L' or not f[3] or f[3][0][0] != 'A' or f[3][0][3] != "define":
                continue
            if len(f[3]) > 1 and f[3][1][0] == 'L' and f[3][1][3] and f[3][1][3][0][0] == 'A':
                name = f[3][1][3][0][3]
                params = []
                for p in f[3][1][3][1:]:
                    if p[0] == 'V' and len(p[3]) >= 3 and p[3][0][0] == 'A' and p[3][1][0] == 'A' \
                            and p[3][1][3] == ':':
                        params.append((p[3][0][3], t[p[3][2][1]:p[3][-1][2]]))
                    else:
                        params.append((None, None))
                defs[name].append((rel, params))
    defs = dict(defs)
    with open(cache, "wb") as fh:
        pickle.dump({"stamp": stamp, "texts": texts, "parsed": parsed, "defs": defs}, fh)
    return texts, parsed, defs
