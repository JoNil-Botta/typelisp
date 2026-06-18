;: Broadcasts are allowed in scan bodies, but not in scan value expressions.
(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (spmd-broadcast (array-ref xs i) 0)
    unit))