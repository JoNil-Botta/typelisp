#!/usr/bin/env python3
"""resloop2.py ORIG.tl INVENTORY.tsv CAND_LINES SIGS OUTDIR: flip-and-revert
over site flips (flip.py) and consumer parameter flips (sigflip.py) together.

Each round applies the surviving signature flips, then the surviving site flips,
typechecks src/main.tl, and reverts by attribution:
  - an argument error naming a converted consumer whose parameter now wants a
    reference (expected (& ...)), or a non-place borrow on a line that calls a
    converted consumer: revert that consumer;
  - otherwise the site flips of the function holding the error;
  - otherwise, if that function is a converted consumer, its conversion.
Outputs kept-sites.txt, kept-sigs.txt, reverted.tsv (kind, key, round, message)."""
import os
import re
import subprocess
import sys

W = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f'
T = W + '/target/exp/tools'
orig, inv, cand_path, sigs_path, outdir = sys.argv[1:6]
os.makedirs(outdir, exist_ok=True)
func_of = {}
for line in open(inv):
    if line.startswith('# '):
        continue
    f = line.rstrip('\n').split('\t')
    func_of[int(f[1].split(':')[1])] = f[2]
sites = [int(x) for x in open(cand_path).read().split()]
sigs = [tuple(l.split()) for l in open(sigs_path) if l.strip()]
src_lines = open(orig).read().split('\n')
tops = [i + 1 for i, l in enumerate(src_lines) if l.startswith('(')]


def func_at(line):
    start = max((t for t in tops if t <= line), default=None)
    if start is None:
        return None
    m = re.match(r'\((?:define|defmacro)\s+\(?([^\s()\[\]]+)', src_lines[start - 1])
    return m.group(1) if m else None


reverted = []
log = open(outdir + '/log.txt', 'w')
rnd = 0
tmp = outdir + '/sig.tl'
while True:
    rnd += 1
    open(outdir + '/cur-sites.txt', 'w').write('\n'.join(map(str, sites)) + '\n')
    open(outdir + '/cur-sigs.txt', 'w').write('\n'.join(' '.join(s) for s in sigs) + '\n')
    subprocess.run(['python3', T + '/sigflip.py', orig, tmp, outdir + '/cur-sigs.txt'], check=True, capture_output=True)
    subprocess.run(['python3', T + '/flip.py', tmp, W + '/src/compiler_optimize.tl', outdir + '/cur-sites.txt'],
                   check=True, capture_output=True)
    chk = outdir + '/check.log'
    subprocess.run(['sh', T + '/check.sh', W, chk], capture_output=True)
    text = open(chk, errors='replace').read()
    if 'reason=success' in text:
        log.write('round %d clean: %d sites, %d sigs\n' % (rnd, len(sites), len(sigs)))
        break
    m = re.search(r'^(error\[[^\n]*)\n', text, re.M)
    if not m:
        log.write('round %d: unparsed\n%s\n' % (rnd, text[:1500]))
        sys.exit(1)
    msg = m.group(1)
    block = text[m.end():]
    nxt = re.search(r'^error\[', block, re.M)
    if nxt:
        block = block[:nxt.start()]
    locs = [(p, int(n)) for p, n in re.findall(r'--> ([^:\n]+):(\d+):', block) if p.endswith('compiler_optimize.tl')]
    if not locs:
        log.write('round %d: no location in compiler_optimize.tl: %s\n' % (rnd, msg))
        sys.exit(1)
    ln = locs[0][1]
    fn = func_at(ln)
    sig_names = {s[0] for s in sigs}
    action = None
    mc = re.search(r"call `([^`]+)` argument \d+(?: \(parameter `([^`]+)`\))? type mismatch: expected \(&", msg)
    if mc and mc.group(1).split('.')[-1] in sig_names:
        name = mc.group(1).split('.')[-1]
        action = ('sig', name)
    if action is None and 'borrow requires' in msg:
        for back in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11]:
            text_line = src_lines[ln - 1 - back] if ln - 1 - back >= 0 else ''
            hit = [s for s in sig_names if re.search(r'\((?:opt\.)?' + re.escape(s) + r'[\s)]', text_line)]
            if hit:
                action = ('sig', hit[0])
                break
    if action is None and any(func_of.get(x) == fn for x in sites):
        action = ('sites', fn)
    if action is None and fn in sig_names:
        action = ('sig', fn)
    if action is None:
        for back in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11]:
            text_line = src_lines[ln - 1 - back] if ln - 1 - back >= 0 else ''
            hit = [s for s in sig_names if re.search(r'\((?:opt\.)?' + re.escape(s) + r'[\s)]', text_line)]
            if hit:
                action = ('sig', hit[0])
                break
    if action is None:
        log.write('round %d: cannot attribute %s line %d: %s\n' % (rnd, fn, ln, msg))
        print('cannot attribute', fn, ln, msg)
        sys.exit(1)
    if action[0] == 'sites':
        drop = [x for x in sites if func_of.get(x) == fn]
        sites = [x for x in sites if x not in drop]
        for x in drop:
            reverted.append(('site', str(x), fn, rnd, msg))
    else:
        sigs = [s for s in sigs if s[0] != action[1]]
        reverted.append(('sig', action[1], fn, rnd, msg))
    log.write('round %d: %s %s (at %s:%d): %s\n' % (rnd, action[0], action[1], fn, ln, msg[:150]))
    log.flush()
open(outdir + '/kept-sites.txt', 'w').write('\n'.join(map(str, sites)) + '\n')
open(outdir + '/kept-sigs.txt', 'w').write('\n'.join(' '.join(s) for s in sigs) + '\n')
with open(outdir + '/reverted.tsv', 'w') as f:
    for r in reverted:
        f.write('\t'.join(map(str, r)) + '\n')
print('rounds', rnd, 'sites kept', len(sites), 'sigs kept', len(sigs))
