;; Overflowing 2D source stride trap: `rows * w` (2 * 5 = 10) fits in i64, but
;; `(rows - 1) * stride + w` overflows i64 (`stride = INT64_MAX`).
;; The hoisted rectangular guard must detect overflow and fall back to the
;; per-row checked loop, which runs row 0 and aborts on row 1.
(define (fill-huge-stride
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [stride : i64]
  [rows : i64]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (+ (array-ref src (+ (* y stride) x)) 1))))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    (fill-huge-stride (&mut out) (& src) 9223372036854775807 2 5)
    0))