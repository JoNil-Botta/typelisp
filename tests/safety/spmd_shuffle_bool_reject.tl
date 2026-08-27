;: SPEC SPMD contract: first shuffle slice supports numeric scalar lanes only.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(define (main
  [xs : (__tl_dyn-array bool)]
  [out : (__tl_dyn-array bool)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (spmd-shuffle (array-ref xs i) 0))))