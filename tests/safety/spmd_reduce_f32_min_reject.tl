;: SPEC SPMD contract: f32 reductions add sum only; min/max remain integer-only.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (main [xs : (Array f32)] [n : i64] [seed : f32]) : f32
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))