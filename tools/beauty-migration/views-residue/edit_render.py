import json

R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
p = R + "src/compiler_ir_types.tl"
s = open(p).read()
a = '''(define (compiler-ir-value-render [value : CompilerIrValue]) : String
  (match value'''
b = '''(define (compiler-ir-value-render [value : (& CompilerIrValue)]) : String
  (match value'''
assert s.count(a) == 1
s = s.replace(a, b)
i = s.index(b)
seg_end = s.index('(define (compiler-ir-value-seq-render-from', i)
seg = s[i:seg_end]
seg2 = seg.replace('    [(String value) value]\n', '    [(String value) (string.copy value)]\n')
assert seg2 != seg
s = s[:i] + seg2 + s[seg_end:]
open(p, 'w').write(s)
p2 = R + 'target/exp/residue/cons2.json'
st = json.load(open(p2))
st['failed'].pop('compiler-ir-value-render', None)
st['converted']['compiler-ir-value-render'] = {'param': 'value', 'parent': '', 'def': 'manual'}
json.dump(st, open(p2, 'w'), indent=1)
print("ok")
