;; Backend-observable lane identity of rank-2 row-local gangs (#7191).
;;
;; Three rows of width 13. Each element stores `program-count * 10 +
;; program-index`, in i64 and in i32 lanes. Gangs are row-local, so
;; `program-index` restarts at 0 on every row and a row's partial tail still
;; reports the full `program-count`. The exit code is the low byte of
;; `sum(i64) + 3 * sum(i32)`; per row:
;;   i64  scalar 130 (one lane); AVX2 538 (3 gangs of 4, then a 1-lane tail);
;;        AVX-512 1078 (a gang of 8, then a 5-lane tail)
;;   i32  130 in every mode: narrowing the i64 lane identity to i32 lanes needs
;;        vector conversions (#7162), so these rows take the exact scalar row,
;;        one lane wide, as the same 1-D body has no SIMD plan either.
(define (fill64 [out : (&mut out (__tl_dyn-array i64))] [w : i64]) : unit
  (foreach
    ([y : i64 0 3] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (+ (* (program-count) 10) (program-index)))))

(define (fill32 [out : (&mut out (__tl_dyn-array i32))] [w : i64]) : unit
  (foreach
    ([y : i64 0 3] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (cast (+ (* (program-count) 10) (program-index)) : i32))))

(define (main) : i64
  (let
    [w : i64 13]
    [out64 : (__tl_dyn-array i64) (__tl_make-array i64 (* 3 w))]
    [out32 : (__tl_dyn-array i32) (__tl_make-array i32 (* 3 w))]
    [i : i64 0]
    [sum : i64 0]
    (fill64 (&mut out64) w)
    (fill32 (&mut out32) w)
    (while (< i (* 3 w))
      (set!
        sum
        (+ sum (+ (array-ref out64 i) (* 3 (cast (array-ref out32 i) : i64)))))
      (set! i (+ i 1)))
    (bit-and sum 0xff)))