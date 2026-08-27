;: SPEC SPMD contract: masked-if branches do not yet support gather reads.
(define (main
  [xs : (__tl_dyn-array i64)]
  [ix : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (set! (array-ref out i) (array-ref xs (array-ref ix i)))
      (set! (array-ref out i) 0))))