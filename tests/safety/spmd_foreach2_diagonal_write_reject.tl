;: `out[y + x]` maps (0, 1) and (1, 0) to one element.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach ([y : i64 0 h] [x : i64 0 w]) (set! (array-ref out (+ y x)) 1)))

(define (main) : i64
  0)