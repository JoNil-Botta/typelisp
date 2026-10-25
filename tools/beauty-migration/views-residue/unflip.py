"""unflip.py FILE:LINE...: turn compiler-ir-*-seq-borrow back into -seq-ref on the listed lines."""
import re
import sys

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/'
by = {}
for e in sys.argv[1:]:
    f, ln = e.rsplit(':', 1)
    by.setdefault(f, []).append(int(ln))
for f, lns in by.items():
    lines = open(R + f).read().split('\n')
    for ln in lns:
        new = re.sub(r'(compiler-ir-[a-z-]+)-seq-borrow\b', r'\1-seq-ref', lines[ln - 1])
        assert new != lines[ln - 1], (f, ln)
        lines[ln - 1] = new
    open(R + f, 'w').write('\n'.join(lines))
print('ok')
