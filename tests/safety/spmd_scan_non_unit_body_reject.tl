;: Scan bodies run for effects and must have type unit.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.

(define (bad [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) prefix))