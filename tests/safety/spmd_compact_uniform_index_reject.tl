(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : i64
  (spmd-compact
    ([_i : i64 0 n] [slot : i64 0])
    true
    (set! (array-ref out 0) slot)))