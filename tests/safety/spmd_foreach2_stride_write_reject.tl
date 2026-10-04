;: A row stride other than the exact inner span (here the outer span) can make
;: rows overlap.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach ([y : i64 0 h] [x : i64 0 w]) (set! (array-ref out (+ (* y h) x)) 1)))

(define (main) : i64
  0)