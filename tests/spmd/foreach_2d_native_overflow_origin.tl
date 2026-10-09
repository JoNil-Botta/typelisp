;; Rank-2 row-local gangs (#7191): a base near the top of i64 makes the
;; row-major index wrap to a negative value. The row origin is far past the
;; array, so the row takes the scalar row, which aborts at its first store in
;; every mode.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [base : i64] [w : i64]) : unit
  (foreach
    ([y : i64 0 2] [x : i64 0 w])
    (set! (array-ref out (+ base (+ (* y w) x))) x)))

(define (main) : i64
  (let
    [w : i64 8]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (* 4 w))]
    (fill (&mut out) (- 9223372036854775807 3) w)
    0))