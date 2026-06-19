;: Scan values use the same pure first-slice rules as spmd-reduce values.
(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (let
      [ignored : unit (array-set! xs i 0)]
      (array-ref xs i))
    unit))