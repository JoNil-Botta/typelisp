(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (begin
    (spmd-scan
      sum
      ([i : i64 0 n] [prefix : i64 0])
      i
      (set! (array-ref out 0) prefix))
    (foreach ([i : i64 0 n]) (set! (array-ref out 0) i))))