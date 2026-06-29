;: SPEC SPMD contract: masked branches do not support spmd-shuffle yet.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i (spmd-shuffle (array-ref xs i) 0))
      (array-set! out i (array-ref xs i)))))