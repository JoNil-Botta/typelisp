;: SPEC SPMD contract: min/max reductions support integer lanes only.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main [xs : (Array f64)] [n : i64] [seed : f64]) : f64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))