R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
p = R + "src/compiler_ir_types.tl"
s = open(p).read()
b = '''  (if (>= position (compiler-ir-instr-seq-count instrs))
    index
    (match (compiler-ir-instr-seq-ref instrs position)
      [(Pack _ words ty)
        (compiler-ir-representation-collect-group-instrs-from
          type-segment-bases
          (compiler-ir-representation-merge-group-type
            type-segment-bases
            index
            (& ty)
            (compiler-ir-value-seq-count words)
            (compiler-ir-representation-pack-class-mask (& types) (& words) 0 0))
          types
          instrs
          (+ position 1))]
      [_
        (compiler-ir-representation-collect-group-instrs-from
          type-segment-bases
          index
          types
          instrs
          (+ position 1))])))
'''
a = '''  (if (>= position (compiler-ir-instr-seq-count instrs))
    index
    ;; The walk recurses outside the match: a self tail call inside the arms
    ;; of a match on a borrowed element is not turned into a loop.
    (compiler-ir-representation-collect-group-instrs-from
      type-segment-bases
      (match (compiler-ir-instr-seq-borrow instrs position)
        [(Pack _ words ty)
          (compiler-ir-representation-merge-group-type
            type-segment-bases
            index
            ty
            (compiler-ir-value-seq-count words)
            (compiler-ir-representation-pack-class-mask (& types) words 0 0))]
        [_ index])
      types
      instrs
      (+ position 1))))
'''
assert s.count(a) == 1
s = s.replace(a, b)
open(p, "w").write(s)
print("ok")
