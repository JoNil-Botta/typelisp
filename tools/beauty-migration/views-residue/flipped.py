"""flipped.py [BASE]: added lines containing seq-borrow in my diff vs BASE (default origin/main),
with the enclosing top-level form."""
import re
import subprocess
import sys

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3'
base = sys.argv[1] if len(sys.argv) > 1 else 'origin/main'
for f in ['src/compiler_backend.tl', 'src/compiler_ir_types.tl', 'src/compiler_regalloc.tl',
          'src/compiler_lower.tl', 'src/compiler_liveness.tl']:
    d = subprocess.run(['git', '-C', R, 'diff', '-U0', base, '--', f], capture_output=True, text=True).stdout
    lines = open(R + '/' + f).read().split('\n')
    ln = 0
    for l in d.split('\n'):
        m = re.match(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', l)
        if m:
            ln = int(m.group(1))
            continue
        if l.startswith('+') and not l.startswith('+++'):
            if 'seq-borrow' in l:
                i = ln
                while not lines[i - 1].startswith('('):
                    i -= 1
                print(f'{f}:{ln}\t{lines[i - 1][:75]}')
            ln += 1
