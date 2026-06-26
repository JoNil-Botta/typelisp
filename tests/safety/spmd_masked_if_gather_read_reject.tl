;: SPEC SPMD contract: masked-if branches do not yet support gather reads.
(import stdlib.array)

(define (main
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array.array-ref xs i) 0)
      (array.array-set! out i (array.array-ref xs (array.array-ref ix i)))
      (array.array-set! out i 0))))