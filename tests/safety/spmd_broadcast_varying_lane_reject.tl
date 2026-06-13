;: SPEC SPMD contract: spmd-broadcast source lane must be uniform.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (spmd-broadcast (array-ref xs i) i))))