;: Inside a nested foreach the rank-2 coordinates are outer values: every inner
;: iteration would write the same row-major element.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach
    ([y : i64 0 h] [x : i64 0 w])
    (foreach ([i : i64 0 2]) (set! (array-ref out (+ (* y w) x)) i))))

(define (main) : i64
  0)