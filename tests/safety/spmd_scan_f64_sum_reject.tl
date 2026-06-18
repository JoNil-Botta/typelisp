;: SPEC SPMD contract: floating-point scan ordering is deferred.
(define (bad [xs : (Array f64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : f64 0.0])
    (array-ref xs i)
    unit))
