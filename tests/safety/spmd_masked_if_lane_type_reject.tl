;: SPEC SPMD contract: masked-if branches reject unsupported lane result types.
(define (main
  [xs : (__tl_dyn-array String)]
  [out : (__tl_dyn-array String)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> i 0)
      (set! (array-ref out i) (array-ref xs i))
      (set! (array-ref out i) ""))))