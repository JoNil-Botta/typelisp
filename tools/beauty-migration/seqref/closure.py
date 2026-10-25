#!/usr/bin/env python3
# closure.py FILE SITES.TSV: the functions that must gain a blocks parameter
# when OptCfgIndex lookups take the function's block list. Seeds are the
# enclosing functions of SITES.TSV that have no CompilerIrBlockList /
# CompilerIrFunction parameter; a caller is added when it has no such
# parameter either. Prints the closure grouped by name prefix, with call-site
# counts.
import re
import sys
from collections import defaultdict

path, sites = sys.argv[1], sys.argv[2]
text = open(path).read()
lines = text.split('\n')
namere = re.compile(r'^\((?:define|define-macro|defmacro) \(?([^\s()]+)')
topre = re.compile(r'^\(')
funcs = {}
order = []
cur = None
for n, line in enumerate(lines):
    if topre.match(line):
        m = namere.match(line)
        cur = m.group(1) if m else None
        if cur is not None and cur not in funcs:
            funcs[cur] = {'start': n, 'body': []}
            order.append(cur)
        elif cur is not None:
            cur = None
    if cur is not None:
        funcs[cur]['body'].append(line)


def sig_of(name):
    body = funcs[name]['body']
    out = []
    for line in body[:16]:
        out.append(line)
        if re.search(r'\]\)\s*:', line) or (len(out) == 1 and re.search(r'\)\s*:\s*\S', line)):
            break
    return ' '.join(out)


def has_blocks(name):
    s = sig_of(name)
    return bool(re.search(r'CompilerIrBlockList|CompilerIrFunction', s))


seeds = []
for row in open(sites):
    f = row.split('\t')[1]
    if f in funcs and f not in seeds:
        seeds.append(f)
need = [s for s in seeds if not has_blocks(s) and not s.startswith('opt-cfg-index-')]
callre_cache = {}
callers = defaultdict(set)
names = set(funcs)
tok = re.compile(r'\(([a-z][a-z0-9_.?!*-]*)')
for name in order:
    for line in funcs[name]['body'][1:]:
        for t in tok.findall(line):
            if t in names and t != name:
                callers[t].add(name)
closure = set(need)
work = list(need)
while work:
    f = work.pop()
    for c in callers[f]:
        if c not in closure and not has_blocks(c):
            closure.add(c)
            work.append(c)
print('seeds', len(seeds), 'seeds without blocks', len(need), 'closure', len(closure))
groups = defaultdict(list)
for f in sorted(closure):
    key = '-'.join(f.split('-')[:2])
    groups[key].append(f)
for k in sorted(groups, key=lambda k: -len(groups[k])):
    print(len(groups[k]), k, ' '.join(groups[k]))
