;: Scan values use the same pure first-slice rules as spmd-reduce values.
; Compatibility exception for #3772: SPMD value operands still use bare array
; helpers so the checker sees compiler array ASTs.
(import stdlib.array)

(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (let
      [ignored : unit (array-set! xs i 0)]
      (array-ref xs i))
    unit))