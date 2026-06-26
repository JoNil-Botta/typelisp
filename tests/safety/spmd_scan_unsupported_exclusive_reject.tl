;: Exclusive and gang-local scan variants are deferred; only inclusive range-wide scans are supported.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan exclusive ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) unit))