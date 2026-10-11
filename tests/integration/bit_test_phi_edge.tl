;; A bit test whose successor has phis still lowers to `bt`.
;;
;; An or-pattern arm, or any same-target classifier chain, inside a loop
;; becomes a windowed bit test. When the arm's body is shared with the loop's
;; merge block, that block carries the loop-carried counter's phi, so the
;; branch out of the bit test owes phi copies. The fused `bt` + jcc now takes
;; those copies on an edge block behind the jcc, as a fused compare does,
;; instead of falling back to a variable shift (tests/codegen/asm-shape.cases:
;; case bit-test-phi-edge).
;;
;; The never-taken self-recursion keeps the kernel out of the opt2 inliner, so
;; it keeps its own emitted symbol for the assembly-shape gate.
(defenum Decl
  (Module i64)
  (Def i64)
  (DefFn i64)
  (DefStruct i64)
  (DefEnum i64)
  (DefMacro i64)
  (DefConst i64)
  (DefGlobal i64)
  (DefExtern i64)
  (DefType i64)
  (Import i64)
  (IncludeStr i64)
  (IncludeStrComptime i64)
  (IncludeStrLzss i64)
  (IncludeBin i64)
  (Other i64)
  (Test i64)
  (Last i64))

;; Counts the declarations that are not module plumbing.
(define (count-defs [decls : (& d (Array Decl 8))] [poke : i64]) : i64
  (if (< poke 0)
    (count-defs decls (+ poke 1))
    (let
      [n : i64 0]
      [i : i64 0]
      (while (< i 8)
        (match (array-ref decls i)
          [(or (Module _) (Import _) (IncludeStr _) (IncludeStrComptime _)
               (IncludeStrLzss _) (IncludeBin _) (Test _))
            unit]
          [_ (set! n (+ n 1))])
        (set! i (+ i 1)))
      n)))

(define (main) : i64
  (let
    [decls : (Array Decl 8)
      (array
        (Decl.Def 1)
        (Decl.Module 2)
        (Decl.Import 3)
        (Decl.Test 4)
        (Decl.Last 5)
        (Decl.DefFn 6)
        (Decl.IncludeBin 7)
        (Decl.Other 8))]
    (+ 38 (count-defs (& decls) 0))))