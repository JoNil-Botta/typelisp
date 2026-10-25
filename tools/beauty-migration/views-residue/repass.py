"""repass.py BASE: for every parameter in my files that is (& T) now but was T at BASE, rewrite view
arguments `(...-shared-view x)` at that position in calls to the function into `x` (free forms only)."""
import glob
import os
import re
import subprocess
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3'
MINE = ['src/compiler_backend.tl', 'src/compiler_ir_types.tl', 'src/compiler_regalloc.tl',
        'src/compiler_lower.tl', 'src/compiler_liveness.tl']
held = set()
for p in glob.glob(R + '/target/exp/residue/funcs-*.txt'):
    for line in open(p):
        f, n = line.rstrip('\n').split('\t')
        held.add((f, n.split(' ', 1)[-1]))


def is_free(rel, name):
    return rel in MINE and (rel, name) not in held


def params(t):
    out = {}
    for m in re.finditer(r'^\(define \(([^\s)]+)', t, re.M):
        i = t.index('(', m.start() + 1)
        d = 0
        j = i
        while True:
            c = t[j]
            if c in '([':
                d += 1
            elif c in ')]':
                d -= 1
                if d == 0:
                    break
            j += 1
        out[m.group(1)] = dict(re.findall(r'\[([^\s\[\]]+) : (\(&[^\]]*\)|[^\]]*)\]', t[i:j + 1]))
    return out


total = 0
for f in MINE:
    old = subprocess.run(['git', '-C', R, 'show', sys.argv[1] + ':' + f], capture_output=True, text=True).stdout
    a = params(old)
    b = params(open(R + '/' + f).read())
    for name, ps in b.items():
        if name not in a:
            continue
        for p, ty in ps.items():
            if ty.startswith('(&') and p in a[name] and not a[name][p].startswith('(&'):
                eds = prepass.view_args(R, MINE, is_free, None, name, p)
                if eds:
                    total += len(eds)
                    print(name, p, len(eds))
print('total', total)
