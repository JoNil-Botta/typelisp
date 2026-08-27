;: SPEC SPMD contract: masked-if branches reject allocations that can escape.
(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [tmp : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (set! (array-ref out i) (array-ref xs i)))
      (set! (array-ref out i) 0))))