;: SPEC SPMD contract: masked-if branches reject nested foreach.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (foreach ([j : i64 0 n]) (array-set! out j (array-ref xs j)))
      (array-set! out i 0))))