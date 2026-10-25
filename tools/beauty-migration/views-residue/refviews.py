"""refviews.py FILE...: views `(...-shared-view P)` of a parameter P declared `(& ...)` in the
enclosing function: these read the reference through its own address (a stack slot) and copy
the referent. Prints file:line, function, param, and whether the view is a match scrutinee."""
import re
import sys

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/'
tot = 0
scrut = 0
for f in sys.argv[1:]:
    text = open(R + f).read()
    for m in re.finditer(r'^\(define \(([^\s)]+)', text, re.M):
        i = text.index('(', m.start() + 1)
        d = 0
        j = i
        while True:
            c = text[j]
            if c in '([':
                d += 1
            elif c in ')]':
                d -= 1
                if d == 0:
                    break
            j += 1
        refs = {p for p, ty in re.findall(r'\[([^\s\[\]]+) : (\(&[^\]]*\)|[^\]]*)\]', text[i:j + 1])
                if ty.startswith('(&') and not ty.startswith('(&mut')}
        if not refs:
            continue
        end = text.find('\n(', j)
        body = text[j:end if end > 0 else len(text)]
        for v in re.finditer(r'(\(match )?\((?:[a-z_]+\.)?[a-z0-9-]*-shared-view\s+([A-Za-z0-9_?!*-]+)\)', body):
            if v.group(2) in refs:
                tot += 1
                if v.group(1):
                    scrut += 1
                line = text.count('\n', 0, j + v.start()) + 1
                print(f'{f}:{line}\t{m.group(1)}\t{v.group(2)}\t{"match" if v.group(1) else "arg"}')
print('total', tot, 'match-scrutinee', scrut, file=sys.stderr)
