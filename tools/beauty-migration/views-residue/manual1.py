R = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
p = R + "src/compiler_backend.tl"
s = open(p).read()
for a, b in [
    ('''                                    (& (compiler-backend-global-shared-view
                                      load-ty2)))''', '''                                    load-ty2)'''),
    ('''                                      (& (compiler-backend-global-shared-view
                                        offset2))''', '''                                      offset2'''),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(p, "w").write(s)

p = R + "src/compiler_ir_types.tl"
s = open(p).read()
a = '''(define (compiler-ir-call-args-array-render
  [values : (& (__tl_dyn-array CompilerIrValue))]
  [index : i64]) : String
  (if (>=
    index
    (array-length (owned_view.compiler-owned-reference-shared-view values)))
    ""
    (str_cat.str-cat
      (compiler-ir-value-render
        (& (compiler-ir-array-shared-view
          (owned_view.compiler-owned-reference-shared-view values)
          index)))
      (if (=
        (+ index 1)
        (array-length (owned_view.compiler-owned-reference-shared-view values)))'''
b = '''(define (compiler-ir-call-args-array-render
  [values : (& (__tl_dyn-array CompilerIrValue))]
  [index : i64]) : String
  (if (>= index (array-length values))
    ""
    (str_cat.str-cat
      (compiler-ir-value-render (& (array-ref values index)))
      (if (= (+ index 1) (array-length values))'''
assert s.count(a) == 1
s = s.replace(a, b)
open(p, "w").write(s)
print("ok")
