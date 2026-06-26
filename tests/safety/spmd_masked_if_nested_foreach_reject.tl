;: SPEC SPMD contract: masked-if branches reject nested foreach.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array.array-ref xs i) 0)
      (foreach ([j : i64 0 n]) (array.array-set! out j (array.array-ref xs j)))
      (array.array-set! out i 0))))