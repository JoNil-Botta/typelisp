;: Exclusive and gang-local scan variants are deferred; only inclusive range-wide scans are supported.
(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan exclusive ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) unit))