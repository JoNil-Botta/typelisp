;: SPEC SPMD contract: floating-point scan ordering remains deferred for f32.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (bad [xs : (Array f32)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : f32 (cast 0.0 : f32)])
    (array-ref xs i)
    unit))