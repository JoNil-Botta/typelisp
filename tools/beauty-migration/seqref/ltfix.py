#!/usr/bin/env python3
# ltfix.py: typecheck src/main.tl; on an E0205 escape error, name the `blocks`
# lifetime ([blocks : (& ir.CompilerIrBlockList)] -> (& blocks ...)) in the
# compiler_optimize.tl function enclosing the first compiler_optimize.tl
# location of the error, and repeat. Stops on success or another error.
import re
import subprocess
import sys

W = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f'
P = W + '/src/compiler_optimize.tl'
LOG = W + '/target/exp/c1/chk.log'
for it in range(40):
    subprocess.run(['sh', W + '/target/exp/tools/check.sh', W, LOG], capture_output=True)
    log = open(LOG).read()
    if 'Type checking passed' in log:
        print('passed after', it, 'fixes')
        sys.exit(0)
    m = re.search(r'^error\[(E\d+)\].*$', log, re.M)
    if not m or m.group(1) != 'E0205':
        print('other error:', m.group(0) if m else log[-500:])
        sys.exit(1)
    rest = log[m.start():]
    loc = re.search(r'--> src/compiler_optimize\.tl:(\d+):', rest)
    if not loc:
        print('no optimize location:', rest[:800])
        sys.exit(1)
    line = int(loc.group(1))
    lines = open(P).read().split('\n')
    k = line - 1
    while k >= 0 and not re.match(r'^\((?:define|defmacro) ', lines[k]):
        k -= 1
    name = re.match(r'^\((?:define|defmacro) \(?([^\s()]+)', lines[k]).group(1)
    fixed = False
    for j in range(k, min(k + 20, len(lines))):
        if '[blocks : (& ir.CompilerIrBlockList)]' in lines[j]:
            lines[j] = lines[j].replace('[blocks : (& ir.CompilerIrBlockList)]',
                                        '[blocks : (& blocks ir.CompilerIrBlockList)]')
            fixed = True
            break
    if not fixed:
        print('no elided blocks param in', name, 'at line', line)
        sys.exit(1)
    open(P, 'w').write('\n'.join(lines))
    print('named blocks lifetime in', name)
print('gave up')
