#!/usr/bin/env python3
"""resloop3.py ORIG.tl INVENTORY.tsv CAND_LINES OUTDIR [MAX_FIXES_PER_FN]:
flip-and-revert with copy-at-the-boundary fixes.

Each round flips the surviving candidate sites (flip.py), applies the recorded
fixes in order, and typechecks. On an error inside a function holding flipped
sites:
  expected CompilerIrValue, found (& .. CompilerIrValue)  wrap the expression at
      the error column in (ir.compiler-ir-clone-value ..)
  expected AstType, found (& .. AstType)                  wrap it in (ast.ty-node-persist ..)
  clone unsupported type (& .. AstType)                    (clone X) -> (ast.ty-node-persist X)
anything else, a repeated location, or more than MAX fixes in one function:
revert the function's sites and fixes. Outputs kept-sites.txt, fixes.tsv
(function, line, col, kind) and reverted.tsv (line, function, round, message)."""
import os
import re
import subprocess
import sys

W = '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f'
T = W + '/target/exp/tools'
orig, inv, cand_path, outdir = sys.argv[1:5]
max_fix = int(sys.argv[5]) if len(sys.argv) > 5 else 6
os.makedirs(outdir, exist_ok=True)
func_of = {}
for line in open(inv):
    if line.startswith('# '):
        continue
    f = line.rstrip('\n').split('\t')
    func_of[int(f[1].split(':')[1])] = f[2]
sites = [int(x) for x in open(cand_path).read().split()]
src_lines = open(orig).read().split('\n')
tops = [i + 1 for i, l in enumerate(src_lines) if l.startswith('(')]


def func_at(line):
    start = max((t for t in tops if t <= line), default=None)
    if start is None:
        return None
    m = re.match(r'\((?:define|defmacro)\s+\(?([^\s()\[\]]+)', src_lines[start - 1])
    return m.group(1) if m else None


def expr_end(text, i):
    if text[i] in '([':
        depth = 0
        j = i
        while j < len(text):
            c = text[j]
            if c == '"':
                j += 1
                while j < len(text) and text[j] != '"':
                    j += 2 if text[j] == '\\' else 1
            elif c in '([':
                depth += 1
            elif c in ')]':
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return len(text)
    m = re.match(r'[^\s()\[\]]+', text[i:])
    return i + (m.end() if m else 1)


def apply_fixes(text, fixes):
    lines = text.split('\n')
    for fn, ln, col, kind in fixes:
        s = lines[ln - 1]
        i = col - 1
        if i >= len(s):
            continue
        j = expr_end(s, i)
        if j >= len(s) and s[i] in '([' and s.count('(', i) > s.count(')', i):
            continue
        e = s[i:j]
        if kind == 'value':
            r = '(ir.compiler-ir-clone-value %s)' % e
        elif kind == 'type':
            r = '(ast.ty-node-persist %s)' % e
        elif kind == 'clone-type':
            r = re.sub(r'^\(clone\s', '(ast.ty-node-persist ', e)
        else:
            continue
        lines[ln - 1] = s[:i] + r + s[j:]
    return '\n'.join(lines)


fixes = []  # (fn, line, col, kind)
reverted = []
seen = set()
log = open(outdir + '/log.txt', 'w')
rnd = 0
flipped = outdir + '/flipped.tl'
while True:
    rnd += 1
    open(outdir + '/cur-sites.txt', 'w').write('\n'.join(map(str, sites)) + '\n')
    subprocess.run(['python3', T + '/flip.py', orig, flipped, outdir + '/cur-sites.txt'], check=True,
                   capture_output=True)
    text = apply_fixes(open(flipped).read(), fixes)
    open(W + '/src/compiler_optimize.tl', 'w').write(text)
    chk = outdir + '/check.log'
    subprocess.run(['sh', T + '/check.sh', W, chk], capture_output=True)
    out = open(chk, errors='replace').read()
    if 'reason=success' in out:
        log.write('round %d clean: %d sites, %d fixes\n' % (rnd, len(sites), len(fixes)))
        break
    m = re.search(r'^(error(?:\[[^\]]*\])?:[^\n]*)\n', out, re.M)
    if not m:
        log.write('round %d: unparsed\n%s\n' % (rnd, out[:1500]))
        sys.exit(1)
    msg = m.group(1)
    block = out[m.end():]
    nxt = re.search(r'^error\[', block, re.M)
    if nxt:
        block = block[:nxt.start()]
    locs = [(int(a), int(b)) for p, a, b in re.findall(r'--> ([^:\n]+):(\d+):(\d+)', block)
            if p.endswith('compiler_optimize.tl')]
    if not locs:
        log.write('round %d: no location: %s\n' % (rnd, msg))
        sys.exit(1)
    ln, col = locs[0]
    fn = func_at(ln)
    if not any(func_of.get(x) == fn for x in sites):
        log.write('round %d: error in %s:%d without flipped sites: %s\n' % (rnd, fn, ln, msg))
        print('error without flipped sites', fn, ln, msg)
        sys.exit(1)
    kind = None
    if re.search(r'expected compiler_ir_types/CompilerIrValue, found \(&[^)]*CompilerIrValue\)', msg):
        kind = 'value'
    elif re.search(r'expected compiler_ast_types/AstType, found \(&[^)]*AstType\)', msg):
        kind = 'type'
    elif re.search(r'clone unsupported type \(&[^)]*AstType\)', msg):
        kind = 'clone-type'
    nfix = sum(1 for f in fixes if f[0] == fn)
    key = (ln, col, msg)
    if kind:
        cur = text.split('\n')[ln - 1]
        ci = col - 1
        if ci >= len(cur) or (cur[ci] in '([' and expr_end(cur, ci) >= len(cur) and cur.count('(', ci) > cur.count(')', ci)):
            kind = None
    if kind and key not in seen and nfix < max_fix:
        seen.add(key)
        fixes.append((fn, ln, col, kind))
        log.write('round %d: fix %s %s:%d:%d %s\n' % (rnd, kind, fn, ln, col, msg[:120]))
    else:
        drop = [x for x in sites if func_of.get(x) == fn]
        sites = [x for x in sites if x not in drop]
        fixes = [f for f in fixes if f[0] != fn]
        for x in drop:
            reverted.append((x, fn, rnd, msg))
        log.write('round %d: revert %s (%d sites) at %d: %s\n' % (rnd, fn, len(drop), ln, msg[:150]))
    log.flush()
open(outdir + '/kept-sites.txt', 'w').write('\n'.join(map(str, sites)) + '\n')
with open(outdir + '/fixes.tsv', 'w') as f:
    for x in fixes:
        f.write('\t'.join(map(str, x)) + '\n')
with open(outdir + '/reverted.tsv', 'w') as f:
    for x, fn, r, msg in reverted:
        f.write('%d\t%s\t%d\t%s\n' % (x, fn, r, msg))
print('rounds', rnd, 'sites kept', len(sites), 'fixes', len(fixes))
