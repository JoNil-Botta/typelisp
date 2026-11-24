;; Rank-2 rectangular bound hoisting edge cases:
;; - exact rectangular fit across tail/unroll widths (1, 3, 4, 5, 7, 15, 16, 17, 33)
;; - dual-load integer associative ops (Add, BitXor) in 2D row loops
;; - padded source stride > x_span (exercises safe_div stride guard)
;; - zero source stride (broadcast row)
;; - negative source stride (must fall back cleanly to checked per-row loop)
;; - negative bounds (y0 < 0, x0 < 0) and empty dimensions (including INT64_MIN..INT64_MAX when other dim empty)
;; - huge source stride with 1 row (rows - 1 == 0, no overflow)
;; Exits 42 when every result matches the scalar `while` reference.
(define (rect-add-i64
  [out : (&mut out (__tl_dyn-array i64))]
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [rows : i64]
  [w : i64]
  [c : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (+ (+ (array-ref a (+ (* y w) x)) (array-ref b (+ (* y w) x))) c))))

(define (rect-xor-i64
  [out : (&mut out (__tl_dyn-array i64))]
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [rows : i64]
  [w : i64]
  [c : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (bit-xor
        (bit-xor (array-ref a (+ (* y w) x)) (array-ref b (+ (* y w) x)))
        c))))

(define (rect-strided
  [out : (&mut out (__tl_dyn-array i64))]
  [a : (& a (__tl_dyn-array i64))]
  [out-base : i64]
  [src-base : i64]
  [stride : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ out-base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+ (array-ref a (+ src-base (+ (* y stride) x))) (+ (* y 3) x)))))

(define (fill-sentinel [arr : (&mut arr (__tl_dyn-array i64))] [v : i64]) : unit
  (let
    [i : i64 0]
    [n : i64 (array-length arr)]
    (while (< i n)
      (set! (array-ref arr i) v)
      (+= i 1))))

(define (arrays-equal?
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]) : bool
  (let
    [n : i64 (array-length a)]
    [i : i64 0]
    (when (!= n (array-length b)) (return false))
    (while (< i n)
      (when (!= (array-ref a i) (array-ref b i)) (return false))
      (+= i 1))
    true))

(define (check-strided
  [len : i64]
  [out-base : i64]
  [src-base : i64]
  [stride : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : bool
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [i : i64 0]
    (while (< i len)
      (set! (array-ref a i) (+ (* i 5) 11))
      (set! (array-ref got i) -77777)
      (set! (array-ref want i) -77777)
      (+= i 1))
    (rect-strided (&mut got) (& a) out-base src-base stride y0 y1 x0 x1)
    (when
      (and (< y0 y1) (< x0 x1))
      (let
        [y : i64 y0]
        (while (< y y1)
          (let
            [x : i64 x0]
            (while (< x x1)
              (set!
                (array-ref
                  want
                  (+ out-base (+ (* (- y y0) (- x1 x0)) (- x x0))))
                (+ (array-ref a (+ src-base (+ (* y stride) x))) (+ (* y 3) x)))
              (+= x 1)))
          (+= y 1))))
    (arrays-equal? (& got) (& want))))

(define (main) : i64
  (let
    [widths : (__tl_dyn-array i64) (__tl_make-array i64 9)]
    [wi : i64 0]
    [min64 : i64 (- -9223372036854775807 1)]
    (set! (array-ref widths 0) 1)
    (set! (array-ref widths 1) 3)
    (set! (array-ref widths 2) 4)
    (set! (array-ref widths 3) 5)
    (set! (array-ref widths 4) 7)
    (set! (array-ref widths 5) 15)
    (set! (array-ref widths 6) 16)
    (set! (array-ref widths 7) 17)
    (set! (array-ref widths 8) 33)
    ;; 1. Exact-fit rectangular Add + BitXor across widths and row counts.
    (while (< wi 9)
      (let
        [w : i64 (array-ref widths wi)]
        [rows : i64 5]
        [len : i64 (* rows w)]
        [a : (__tl_dyn-array i64) (__tl_make-array i64 len)]
        [b : (__tl_dyn-array i64) (__tl_make-array i64 len)]
        [got : (__tl_dyn-array i64) (__tl_make-array i64 len)]
        [want : (__tl_dyn-array i64) (__tl_make-array i64 len)]
        [i : i64 0]
        (while (< i len)
          (set! (array-ref a i) (+ (* i 7) 3))
          (set! (array-ref b i) (- (* i 11) 5))
          (+= i 1))
        (fill-sentinel (&mut got) -99999)
        (rect-add-i64 (&mut got) (& a) (& b) rows w 41)
        (set! i 0)
        (while (< i len)
          (set! (array-ref want i) (+ (+ (array-ref a i) (array-ref b i)) 41))
          (+= i 1))
        (when (not (arrays-equal? (& got) (& want))) (return 1))
        (fill-sentinel (&mut got) -88888)
        (rect-xor-i64 (&mut got) (& a) (& b) rows w 99)
        (set! i 0)
        (while (< i len)
          (set!
            (array-ref want i)
            (bit-xor (bit-xor (array-ref a i) (array-ref b i)) 99))
          (+= i 1))
        (when (not (arrays-equal? (& got) (& want))) (return 2)))
      (+= wi 1))
    ;; 2. Padded source stride > x_span (exercises safe_div guard branch).
    (when (not (check-strided 200 3 5 23 0 6 0 15)) (return 3))
    ;; 3. Zero source stride (broadcast row).
    (when (not (check-strided 100 1 3 0 0 4 0 19)) (return 4))
    ;; 4. Negative source stride (must fall back cleanly to per-row checked loop).
    (when (not (check-strided 120 2 80 -19 0 4 0 17)) (return 5))
    ;; 5. Negative y0 and x0 with valid positive indices.
    (when (not (check-strided 200 4 100 17 -3 2 -5 12)) (return 6))
    ;; 6. Empty dimensions, including extreme INT64_MIN..INT64_MAX on the non-empty axis.
    (when
      (not (check-strided 16 0 0 17 0 0 min64 9223372036854775807))
      (return 7))
    (when
      (not (check-strided 16 0 0 17 min64 9223372036854775807 4 4))
      (return 8))
    (when (not (check-strided 16 0 0 -5 5 2 0 10)) (return 9))
    ;; 7. Huge source stride with 1 row (y_span - 1 == 0, so (y_span - 1) * stride == 0).
    (when (not (check-strided 32 0 0 9223372036854775807 0 1 0 17)) (return 10))
    42))