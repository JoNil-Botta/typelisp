(define (fill [out : (__tl_dyn-array i64)]) : unit
  (foreach ([y : i64 0 2] [x : i64 0 4]) (set! (array-ref out 0) (+ (* y 4) x))))