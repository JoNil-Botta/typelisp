;; Partial/ragged 2D slice trap: destination is shorter than rows * w
;; (`out.len = 2 * 17 + 5 = 39`, domain is 4 x 17 = 68).
;; The hoisted rectangular guard must reject and fall back to the exact per-row
;; checked loop, which aborts on element 39 without writing past the array.
(define (fill-rect
  [out : (&mut out (__tl_dyn-array i64))]
  [a : (& a (__tl_dyn-array i64))]
  [rows : i64]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set! (array-ref out (+ (* y w) x)) (+ (array-ref a (+ (* y w) x)) 1))))

(define (main) : i64
  (let
    [w : i64 17]
    [rows : i64 4]
    [a : (__tl_dyn-array i64) (__tl_make-array i64 (* rows w))]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (+ (* 2 w) 5))]
    (fill-rect (&mut out) (& a) rows w)
    0))