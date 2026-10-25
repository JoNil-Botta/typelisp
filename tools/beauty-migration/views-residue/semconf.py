"""semconf.py PR...: added lines in each PR (vs its merge-base with origin/main) that call a function
whose parameter this branch turned into a reference (converted-names.txt)."""
import re
import subprocess
import sys

R = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3'
names = [n.strip() for n in open(R + '/target/exp/residue/converted-names.txt') if n.strip()]
pat = re.compile(r'\((?:[a-z_]+\.)?(' + '|'.join(re.escape(n) for n in names) + r')[\s)]')


def git(*a):
    return subprocess.run(['git', '-C', R, *a], capture_output=True, text=True).stdout


for p in sys.argv[1:]:
    mb = git('merge-base', 'origin/main', f'pr/{p}').strip()
    d = git('diff', mb, f'pr/{p}')
    hits = []
    f = None
    for line in d.split('\n'):
        if line.startswith('+++ '):
            f = line[6:]
        elif line.startswith('+') and not line.startswith('+++'):
            m = pat.search(line)
            if m:
                hits.append((f, m.group(1), line[1:].strip()[:100]))
    print(f'#{p}: {len(hits)}')
    for h in hits[:40]:
        print('   ', *h)
