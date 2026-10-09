;; Rank-2 row-local gangs (#7191): the source is first too short on row 2,
;; whose row origin is still inside it, so the row's protected gangs reach the
;; out-of-bounds read and every mode aborts there.
(define (copy
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 3] [x : i64 0 w])
    (set! (array-ref out (+ (* y w) x)) (+ (array-ref src (+ (* y w) x)) 1))))

(define (main) : i64
  (let
    [w : i64 9]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (* 3 w))]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 (+ (* 2 w) 4))]
    (copy (&mut out) (& src) w)
    0))