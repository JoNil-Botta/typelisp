;: A helper body sees a rank-2 coordinate as a plain varying value, so it cannot
;: prove a row-major write on the caller's domain.
(define (store
  [out : (&mut out (__tl_dyn-array i64))]
  [y : i64]
  [x : i64]
  [w : i64]) : unit
  (set! (array-ref out (+ (* y w) x)) 1))

(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach ([y : i64 0 h] [x : i64 0 w]) (store out y x w)))

(define (main) : i64
  0)