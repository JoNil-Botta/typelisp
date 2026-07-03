;: SPEC SPMD contract: spmd-broadcast source lane must be uniform.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref xs i) i))))