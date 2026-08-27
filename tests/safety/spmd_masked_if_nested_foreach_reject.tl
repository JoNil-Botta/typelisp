;: SPEC SPMD contract: masked-if branches reject nested foreach.

(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (foreach ([j : i64 0 n]) (set! (array-ref out j) (array-ref xs j)))
      (set! (array-ref out i) 0))))