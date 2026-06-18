;: SPEC SPMD contract: masked-if branches do not yet support gather reads.
(define (main
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (array-set! out i (array-ref xs (array-ref ix i)))
      (array-set! out i 0))))