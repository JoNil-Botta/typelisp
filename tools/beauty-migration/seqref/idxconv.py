#!/usr/bin/env python3
# idxconv.py FILE GROUPFILE [--apply]
# Converts the functions named in GROUPFILE (one per line, `name` or
# `name=LIST` where LIST is the block-list expression the function's index was
# built from, default `blocks`) from OptCfgIndex block copies to borrows of the
# function's own list:
#   (opt-cfg-index-find-block IDX L)  -> (opt-cfg-index-find-block-in LIST IDX L)
#   (opt-cfg-index-block IDX I)       -> (opt-cfg-index-block-in LIST IDX I)
#   (compiler-opt-global-array-element-shared-view X.blocks I)
#                                     -> (opt-cfg-block-at LIST I)
# and, inside the arms that bind the borrowed block, drops `(& name)` re-borrows
# of the names the block pattern binds (#9137). Functions without a `blocks`
# parameter get `[blocks : (& blocks ir.CompilerIrBlockList)]` before their
# index/state parameter, and every call of such a function gets `blocks` at
# that position. Prints a report; writes the file only with --apply.
import re
import sys

sys.path.insert(0, '/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp/tools')
import sexp  # noqa: E402

path = sys.argv[1]
group = {}
for line in open(sys.argv[2]):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    if '=' in line:
        k, v = line.split('=', 1)
        group[k.strip()] = v.strip()
    else:
        group[line] = None
apply = '--apply' in sys.argv
text = open(path).read()
nodes = sexp.parse(text)
defs = dict(sexp.toplevel_defines(nodes))
edits = []
report = []


def src(node):
    return text[node['a']:node['b']]


def params_of(fn):
    sig = fn['c'][1]
    out = []
    for i, p in enumerate(sig['c'][1:]):
        if p['k'] == 'vec' and p['c'] and p['c'][0]['k'] == 'atom':
            out.append((i, p['c'][0]['t'], src(p), p))
    return out


LOOKUPS = {'opt-cfg-index-find-block': 'opt-cfg-index-find-block-in',
           'opt-cfg-index-block': 'opt-cfg-index-block-in'}
VIEW = 'compiler-opt-global-array-element-shared-view'


def pattern_names(pat):
    # Names a pattern binds (atoms other than `_`, constructor heads).
    names = []
    if pat['k'] == 'atom':
        if pat['t'] != '_' and not pat['t'][0].isupper():
            names.append(pat['t'])
    elif pat['k'] == 'list':
        for c in pat['c'][1:]:
            names.extend(pattern_names(c))
    return names


def drop_reborrows(body_nodes, names, where):
    for b in body_nodes:
        for n in sexp.walk(b):
            if sexp.head(n) == '&' and len(n['c']) == 2 and n['c'][1]['k'] == 'atom' \
                    and n['c'][1]['t'] in names:
                edits.append((n['a'], n['b'], n['c'][1]['t']))
                report.append(f'  re-borrow dropped: {src(n)} in {where}')


def ref_names_in_arm(arm, block_var_names):
    # In an arm body, names bound by matching a block reference.
    names = set(block_var_names)
    for n in sexp.walk(arm):
        if sexp.head(n) == 'match' and len(n['c']) > 2 and n['c'][1]['k'] == 'atom' \
                and n['c'][1]['t'] in block_var_names:
            for a in n['c'][2:]:
                if a['k'] == 'vec' and a['c']:
                    names.update(pattern_names(a['c'][0]))
    return names


def handle_scrutinee(call, parent, where):
    # `call` yields a borrowed block (maybe-wrapped when maybe=True).
    pass


converted_fns = {}
for name, lst in group.items():
    fn = defs.get(name)
    if fn is None:
        report.append(f'MISSING {name}')
        continue
    keep_sig = lst == '@func'
    lst = 'blocks' if (lst is None or keep_sig) else lst
    ps = params_of(fn)
    has_blocks = keep_sig or (any(p[1] == 'blocks' for p in ps) if lst == 'blocks' else True)
    if keep_sig:
        report.append(f'  {name}: bind `blocks` from its function by hand')
    converted_fns[name] = (fn, lst, has_blocks)
    count = 0
    # parent map for match detection
    parents = {}
    for n in sexp.walk(fn):
        for c in n.get('c', []):
            parents[id(c)] = n
    for n in sexp.walk(fn):
        h = sexp.head(n)
        if h in LOOKUPS:
            count += 1
            hd = n['c'][0]
            edits.append((hd['a'], hd['b'], LOOKUPS[h] + ' ' + lst))
            par = parents.get(id(n))
            if par is not None and sexp.head(par) == 'match' and par['c'][1] is n:
                for arm in par['c'][2:]:
                    if arm['k'] != 'vec' or not arm['c']:
                        continue
                    pat = arm['c'][0]
                    if sexp.head(pat) == 'Some' and len(pat['c']) == 2:
                        inner = pat['c'][1]
                        if inner['k'] == 'atom':
                            names = ref_names_in_arm(arm, {inner['t']})
                        else:
                            names = set(pattern_names(inner))
                        drop_reborrows(arm['c'][1:], names, name)
            else:
                report.append(f'  lookup not a match scrutinee in {name}: {src(par)[:90] if par else "?"}')
        elif h == VIEW and len(n['c']) == 3 and n['c'][1]['k'] == 'atom' \
                and n['c'][1]['t'].endswith('.blocks'):
            count += 1
            recv = n['c'][1]['t'][:-len('.blocks')]
            edits.append((n['a'], n['b'], f'(opt-cfg-index-block-at {lst} {recv} {src(n["c"][2])})'))
            par = parents.get(id(n))
            if par is not None and sexp.head(par) == 'match' and par['c'][1] is n:
                for arm in par['c'][2:]:
                    if arm['k'] == 'vec' and arm['c']:
                        names = set(pattern_names(arm['c'][0]))
                        drop_reborrows(arm['c'][1:], names, name)
            else:
                report.append(f'  view not a match scrutinee in {name}: {src(par)[:90] if par else "?"}')
    for n in sexp.walk(fn):
        if n['k'] == 'atom' and n['t'].endswith('.blocks') and n['t'] != 'blocks':
            report.append(f'  remaining {n["t"]} in {name} at {text.count(chr(10), 0, n["a"]) + 1}')
    report.append(f'{name}: {count} lookups, blocks param {"present" if has_blocks else "ADDED"}, list {lst}')
    if not has_blocks:
        # insert before the first param mentioning an index/state/context
        pos = None
        for i, pname, psrc, pnode in ps:
            if re.search(r'OptCfgIndex|State|OptCfgContext|cfg', psrc):
                pos = (i, pnode)
                break
        if pos is None and ps:
            pos = (ps[0][0], ps[0][3])
        if pos is None:
            sig = fn['c'][1]
            at = sig['c'][0]['b']
            edits.append((at, at, ' [blocks : (& blocks ir.CompilerIrBlockList)]'))
            converted_fns[name] = (fn, lst, False, 0)
        else:
            at = pos[1]['a']
            edits.append((at, at, '[blocks : (& blocks ir.CompilerIrBlockList)]\n  '))
            converted_fns[name] = (fn, lst, False, pos[0])

# calls of functions that gained a parameter
added = {k: v[3] for k, v in converted_fns.items() if len(v) == 4}
for cname, cfn in defs.items():
    for n in sexp.walk(cfn):
        h = sexp.head(n)
        if h in added and n is not cfn['c'][1]:
            argpos = added[h]
            args = n['c'][1:]
            if argpos < len(args):
                at = args[argpos]['a']
                edits.append((at, at, 'blocks '))
            else:
                at = n['b'] - 1
                edits.append((at, at, ' blocks'))
            inscope = cname in group or any(p[1] == 'blocks' for p in params_of(cfn))
            if not inscope:
                report.append(f'CALLER WITHOUT blocks PARAM: {cname} calls {h} (line {text.count(chr(10), 0, n["a"]) + 1})')

edits.sort(key=lambda e: (e[0], e[1]), reverse=True)
last = None
for e in edits:
    if last is not None and e[1] > last[0] and not (e[0] == e[1] == last[0]):
        report.append(f'OVERLAP {e} {last}')
    last = e
print('\n'.join(report))
print(f'{len(edits)} edits')
if apply:
    out = text
    for a, b, t in edits:
        out = out[:a] + t + out[b:]
    open(path, 'w').write(out)
    print('applied')
