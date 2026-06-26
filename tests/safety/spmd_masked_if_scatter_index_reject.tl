;: SPEC SPMD contract: masked-if writes reject scatter-like indexes.
(import stdlib.array)

(define (main
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array.array-ref ix i)]
      (if (> (array.array-ref xs i) 0)
        (array.array-set! out j (array.array-ref xs i))
        (array.array-set! out i 0)))))