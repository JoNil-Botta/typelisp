;: SPEC SPMD contract: unmasked foreach writes reject scatter-like indexes.
(define (main [ix : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array-ref ix i)]
      (array-set! out j i))))