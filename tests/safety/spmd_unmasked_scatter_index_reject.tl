;: SPEC SPMD contract: unmasked foreach writes reject scatter-like indexes.

(define (main
  [ix : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [j : i64 (array-ref ix i)]
      (set! (array-ref out j) i))))