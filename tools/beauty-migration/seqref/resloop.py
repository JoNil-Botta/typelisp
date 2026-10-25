#!/usr/bin/env python3
"""resloop.py ORIG.tl INVENTORY.tsv CAND_LINES OUTDIR: flip-and-revert loop.

Flip every candidate line (flip.py), typecheck src/main.tl in the worktree, and
on an error revert every candidate site of the function holding the error; repeat
until the check passes. Writes OUTDIR/kept.txt (flipped lines that typecheck),
OUTDIR/reverted.tsv (line, function, round, first error line) and a log."""
import os
import re
import subprocess
import sys

W = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f'
T = W + '/target/exp/tools'
orig, inv, cand_path, outdir = sys.argv[1:5]
os.makedirs(outdir, exist_ok=True)
func_of = {}
for line in open(inv):
    if line.startswith('# '):
        continue
    f = line.rstrip('\n').split('\t')
    func_of[int(f[1].split(':')[1])] = f[2]
cand = [int(x) for x in open(cand_path).read().split()]
src_lines = open(orig).read().split('\n')
tops = [i + 1 for i, l in enumerate(src_lines) if l.startswith('(')]


def func_at(line):
    start = max((t for t in tops if t <= line), default=None)
    if start is None:
        return None
    m = re.match(r'\((?:define|defmacro)\s+\(?([^\s()\[\]]+)', src_lines[start - 1])
    return m.group(1) if m else None


keep = list(cand)
reverted = []
log = open(outdir + '/log.txt', 'w')
rnd = 0
while True:
    rnd += 1
    open(outdir + '/cur.txt', 'w').write('\n'.join(map(str, keep)) + '\n')
    subprocess.run(['python3', T + '/flip.py', orig, W + '/src/compiler_optimize.tl', outdir + '/cur.txt'],
                   check=True, capture_output=True)
    chk = outdir + '/check.log'
    subprocess.run(['sh', T + '/check.sh', W, chk], capture_output=True)
    text = open(chk, errors='replace').read()
    if 'reason=success' in text:
        log.write('round %d clean, kept %d\n' % (rnd, len(keep)))
        break
    m = re.search(r'^(error\[[^\n]*)\n', text, re.M)
    if not m:
        log.write('round %d: unparsed failure\n%s\n' % (rnd, text[:2000]))
        print('unparsed failure; see', outdir + '/log.txt')
        sys.exit(1)
    msg = m.group(1)
    block = text[m.end():]
    nxt = re.search(r'^error\[', block, re.M)
    if nxt:
        block = block[:nxt.start()]
    locs = re.findall(r'--> ([^:\n]+):(\d+):', block)
    inside = [(p, int(n)) for p, n in locs if p.endswith('compiler_optimize.tl')]
    path, ln = inside[0] if inside else (locs[0][0] if locs else '?', int(locs[0][1]) if locs else 0)
    if not path.endswith('compiler_optimize.tl'):
        log.write('round %d: error outside compiler_optimize.tl: %s %s:%d\n' % (rnd, msg, path, ln))
        print('error outside the file:', path, ln, msg)
        sys.exit(1)
    fn = func_at(ln)
    drop = [x for x in keep if func_of.get(x) == fn]
    if not drop:
        log.write('round %d: error in %s (line %d) holds no flipped site: %s\n' % (rnd, fn, ln, msg))
        print('error in a function without flipped sites:', fn, ln, msg)
        sys.exit(1)
    for x in drop:
        reverted.append((x, fn, rnd, msg))
    keep = [x for x in keep if x not in drop]
    log.write('round %d: %s line %d -> revert %d sites: %s\n' % (rnd, fn, ln, len(drop), msg[:160]))
    log.flush()
open(outdir + '/kept.txt', 'w').write('\n'.join(map(str, keep)) + '\n')
with open(outdir + '/reverted.tsv', 'w') as f:
    for x, fn, r, msg in reverted:
        f.write('%d\t%s\t%d\t%s\n' % (x, fn, r, msg))
print('rounds', rnd, 'kept', len(keep), 'reverted', len(reverted))
