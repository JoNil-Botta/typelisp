;: SPEC SPMD contract: spmd-shuffle source lane must be i64.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-shuffle (array-ref xs i) true))))