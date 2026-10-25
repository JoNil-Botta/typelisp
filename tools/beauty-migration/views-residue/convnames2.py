"""convnames.py BASE: functions in my files whose header changed between BASE and the working tree."""
import re
import subprocess
import sys

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3'
FILES = sys.argv[2].split(',')


def headers(t):
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
        out[m.group(1)] = re.sub(r'\s+', ' ', t[i:j + 1])
    return out


for f in FILES:
    old = subprocess.run(['git', '-C', R, 'show', sys.argv[1] + ':' + f], capture_output=True, text=True).stdout
    a = headers(old)
    b = headers(open(R + '/' + f).read())
    for n in sorted(b):
        if n in a and a[n] != b[n]:
            print(n)
