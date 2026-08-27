;: SPEC SPMD contract: masked-if writes reject scatter-like indexes.

(define (main
  [xs : (__tl_dyn-array i64)]
  [ix : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array-ref ix i)]
      (if (> (array-ref xs i) 0)
        (set! (array-ref out j) (array-ref xs i))
        (set! (array-ref out i) 0)))))