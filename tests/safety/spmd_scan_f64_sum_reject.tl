;: SPEC SPMD contract: floating-point scan ordering is deferred.
; Compatibility exception for #3772: SPMD value operands still use bare
; array-ref so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (bad [xs : (Array f64)] [n : i64]) : unit
  (spmd-scan sum ([i : i64 0 n] [prefix : f64 0.0]) (array-ref xs i) unit))