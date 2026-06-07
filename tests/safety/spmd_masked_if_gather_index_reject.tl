;: SPEC SPMD contract: masked-if writes reject gather/scatter-like indexes.
(define (main
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array-ref ix i)]
      (if (> (array-ref xs i) 0)
        (array-set! out j (array-ref xs i))
        (array-set! out i 0)))))