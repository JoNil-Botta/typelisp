;; Native rank-2 foreach (#7191): every row runs as row-local gangs over
;; row-major arrays. Each kernel is compared with a scalar `while` reference
;; over 672 domains: widths around every gang size (1-5, 7-9, 15-17, 31-33),
;; 0, 1, 2 and 5 rows, negative and positive lower bounds, and two bases. Both
;; runs start from sentinel-filled arrays and the whole arrays are compared, so
;; a gang that crosses into the next row, writes outside the domain, or keeps
;; the first row's `y` changes the result. The kernels cover i64, i32 and f64
;; lanes, a read-only stencil read at three origins, an in-place update, reads
;; at `x - x0`, a same-program and an imported helper taking `y`, and a bool
;; output that keeps the scalar row, arrays exactly as long as the domain, and
;; a masked store whose first row starts before the array, and reads the row
;; plan must refuse. Exits 42 when every comparison holds, in
;; scalar, AVX2 and AVX-512 alike.
(import foreach_2d_native_helpers as row_helpers)

(define (shade [y : i64] [v : i64]) : i64
  (+ (* v 2) y))

(define (row-major
  [base : i64]
  [y : i64]
  [y0 : i64]
  [x : i64]
  [x0 : i64]
  [x1 : i64]) : i64
  (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))

;; Kernel 0: i64 map with a uniform base and a row-uniform addend.
(define (map-i64
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+
        (* (array-ref src (+ base (+ (* (- y y0) (- x1 x0)) (- x x0)))) 3)
        (* y 7)))))

;; Kernel 1: i32 lanes, written with the span over a zero-based inner index.
(define (map-i32
  [out : (&mut out (__tl_dyn-array i32))]
  [src : (& src (__tl_dyn-array i32))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ (- x x0) (+ base (* (- y y0) (- x1 x0)))))
      (+ (array-ref src (+ (- x x0) (+ base (* (- y y0) (- x1 x0))))) 11))))

;; Kernel 2: f64 lanes.
(define (map-f64
  [out : (&mut out (__tl_dyn-array f64))]
  [src : (& src (__tl_dyn-array f64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (* (array-ref src (+ base (+ (* (- y y0) (- x1 x0)) (- x x0)))) 0.5))))

;; Kernel 3: a read-only stencil, one view per origin.
(define (stencil
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+
        (-
          (array-ref src (+ (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))) 1))
          (array-ref src (- (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))) 1)))
        (array-ref src (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))))))

;; Kernel 4: an in-place update reads and writes one origin, plus a read at
;; `x - x0` through a second array.
(define (accumulate
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+
        (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
        (array-ref src (- x x0))))))

;; Kernel 5: same-program and imported helpers take `y` as an argument.
(define (helpers
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (+
        (shade y (array-ref src (+ base (+ (* (- y y0) (- x1 x0)) (- x x0)))))
        (row_helpers.tint y (array-ref src (- x x0)))))))

;; Kernel 6: a bool output has no lane view, so its rows stay scalar.
(define (threshold
  [out : (&mut out (__tl_dyn-array bool))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (set!
      (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
      (> (array-ref src (+ base (+ (* (- y y0) (- x1 x0)) (- x x0)))) (+ y 40)))))

;; Kernel 7: a masked store skips the first two columns of every row. With a
;; base of -2 the first row's origin is negative although every store that
;; runs is in bounds, so that row must take the scalar row.
(define (masked-skip
  [out : (&mut out (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (when
      (>= (- x x0) 2)
      (set!
        (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
        (+ (* y 100) x)))))

;; Kernel 8: reads the row plan must refuse. One index uses `x` twice, the
;; other adds an offset bound inside the body; both keep their own indexes
;; while the store still goes through its view.
(define (refused
  [out : (&mut out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : unit
  (foreach
    ([y : i64 y0 y1] [x : i64 x0 x1])
    (let
      [k : i64 (- y y0)]
      (set!
        (array-ref out (+ base (+ (* (- y y0) (- x1 x0)) (- x x0))))
        (+
          (array-ref src (- (* 2 (- x x0)) (- x x0)))
          (array-ref src (+ (- x x0) k)))))))

;; The scalar reference of kernel KERNEL at one element K of row Y, column X.
(define (expected-i64
  [kernel : i64]
  [out : (& out (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [k : i64]
  [y : i64]
  [y0 : i64]
  [x : i64]
  [x0 : i64]) : i64
  (cond
    [(= kernel 0) (+ (* (array-ref src k) 3) (* y 7))]
    [(= kernel 3)
      (+ (- (array-ref src (+ k 1)) (array-ref src (- k 1))) (array-ref src k))]
    [(= kernel 4) (+ (array-ref out k) (array-ref src (- x x0)))]
    [(= kernel 8)
      (+ (array-ref src (- x x0)) (array-ref src (+ (- x x0) (- y y0))))]
    [else
      (+
        (shade y (array-ref src k))
        (row_helpers.tint y (array-ref src (- x x0))))]))

(define (fill-i64 [xs : (&mut xs (__tl_dyn-array i64))] [n : i64] [seed : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref xs i) (- (% (+ (* i 37) seed) 101) 50))
      (set! i (+ i 1)))))

(define (same-i64
  [a : (& a (__tl_dyn-array i64))]
  [b : (& b (__tl_dyn-array i64))]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (< i n)
      (when (not (= (array-ref a i) (array-ref b i))) (set! ok false))
      (set! i (+ i 1)))
    ok))

;; Kernels 0, 3, 4 and 5 over one domain.
(define (check-i64
  [kernel : i64]
  [base : i64]
  [y0 : i64]
  [y1 : i64]
  [x0 : i64]
  [x1 : i64]) : bool
  (let
    [n : i64 (+ (+ base (* (- y1 y0) (- x1 x0))) 2)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 (+ n 40))]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [y : i64 y0]
    (fill-i64 (&mut src) (+ n 40) (+ kernel y0))
    (fill-i64 (&mut got) n 777)
    (fill-i64 (&mut want) n 777)
    (cond
      [(= kernel 0) (map-i64 (&mut got) (& src) base y0 y1 x0 x1)]
      [(= kernel 3) (stencil (&mut got) (& src) base y0 y1 x0 x1)]
      [(= kernel 4) (accumulate (&mut got) (& src) base y0 y1 x0 x1)]
      [(= kernel 8) (refused (&mut got) (& src) base y0 y1 x0 x1)]
      [else (helpers (&mut got) (& src) base y0 y1 x0 x1)])
    (while (< y y1)
      (let
        [x : i64 x0]
        (while (< x x1)
          (let
            [k : i64 (row-major base y y0 x x0 x1)]
            (set!
              (array-ref want k)
              (expected-i64 kernel (& want) (& src) k y y0 x x0)))
          (set! x (+ x 1))))
      (set! y (+ y 1)))
    (same-i64 (& got) (& want) n)))

(define (check-i32 [base : i64] [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : bool
  (let
    [n : i64 (+ (+ base (* (- y1 y0) (- x1 x0))) 2)]
    [src : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [got : (__tl_dyn-array i32) (__tl_make-array i32 n)]
    [i : i64 0]
    [ok : bool true]
    (while (< i n)
      (set! (array-ref src i) (cast (- (* i 13) 400) : i32))
      (set! (array-ref got i) (cast -5 : i32))
      (set! i (+ i 1)))
    (map-i32 (&mut got) (& src) base y0 y1 x0 x1)
    (set! i 0)
    (while (< i n)
      (let
        [inside : bool (and (>= i base) (< i (+ base (* (- y1 y0) (- x1 x0)))))]
        [want : i32
          (if inside
            (+ (array-ref src i) (cast 11 : i32))
            (cast -5 : i32))]
        (when (not (= (array-ref got i) want)) (set! ok false)))
      (set! i (+ i 1)))
    ok))

(define (check-f64 [base : i64] [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : bool
  (let
    [n : i64 (+ (+ base (* (- y1 y0) (- x1 x0))) 2)]
    [src : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [got : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [i : i64 0]
    [ok : bool true]
    (while (< i n)
      (set! (array-ref src i) (cast (- (* i 3) 50) : f64))
      (set! (array-ref got i) -1.0)
      (set! i (+ i 1)))
    (map-f64 (&mut got) (& src) base y0 y1 x0 x1)
    (set! i 0)
    (while (< i n)
      (let
        [inside : bool (and (>= i base) (< i (+ base (* (- y1 y0) (- x1 x0)))))]
        [want : f64
          (if inside
            (* (array-ref src i) 0.5)
            -1.0)]
        (when (not (= (array-ref got i) want)) (set! ok false)))
      (set! i (+ i 1)))
    ok))

(define (check-bool [base : i64] [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : bool
  (let
    [n : i64 (+ (+ base (* (- y1 y0) (- x1 x0))) 2)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [got : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [y : i64 y0]
    [ok : bool true]
    (fill-i64 (&mut src) n 5)
    (threshold (&mut got) (& src) base y0 y1 x0 x1)
    (while (< y y1)
      (let
        [x : i64 x0]
        (while (< x x1)
          (let
            [k : i64 (row-major base y y0 x x0 x1)]
            (when
              (not (= (array-ref got k) (> (array-ref src k) (+ y 40))))
              (set! ok false)))
          (set! x (+ x 1))))
      (set! y (+ y 1)))
    ok))

;; Kernel 0 into arrays exactly as long as the domain, so the last row's last
;; gang ends at the array end.
(define (check-exact [base : i64] [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : bool
  (let
    [n : i64 (+ base (* (- y1 y0) (- x1 x0)))]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [y : i64 y0]
    (fill-i64 (&mut src) n 3)
    (map-i64 (&mut got) (& src) base y0 y1 x0 x1)
    (while (< y y1)
      (let
        [x : i64 x0]
        (while (< x x1)
          (let
            [k : i64 (row-major base y y0 x x0 x1)]
            (set!
              (array-ref want k)
              (expected-i64 0 (& want) (& src) k y y0 x x0)))
          (set! x (+ x 1))))
      (set! y (+ y 1)))
    (same-i64 (& got) (& want) n)))

;; Kernel 7 with a base of -2; the domain needs a row and three columns.
(define (check-masked [y0 : i64] [y1 : i64] [x0 : i64] [x1 : i64]) : bool
  (let
    [n : i64 (* (- y1 y0) (- x1 x0))]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [want : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [y : i64 y0]
    (fill-i64 (&mut got) n 9)
    (fill-i64 (&mut want) n 9)
    (masked-skip (&mut got) -2 y0 y1 x0 x1)
    (while (< y y1)
      (let
        [x : i64 (+ x0 2)]
        (while (< x x1)
          (set! (array-ref want (row-major -2 y y0 x x0 x1)) (+ (* y 100) x))
          (set! x (+ x 1))))
      (set! y (+ y 1)))
    (same-i64 (& got) (& want) n)))

;; 0 when every kernel matches its reference on the domain, else the failing
;; kernel plus one.
(define (check-domain
  [base : i64]
  [y0 : i64]
  [rows : i64]
  [x0 : i64]
  [width : i64]) : i64
  (let
    [y1 : i64 (+ y0 rows)]
    [x1 : i64 (+ x0 width)]
    (cond
      [(not (check-i64 0 base y0 y1 x0 x1)) 1]
      [(not (check-i32 base y0 y1 x0 x1)) 2]
      [(not (check-f64 base y0 y1 x0 x1)) 3]
      [(not (check-i64 3 base y0 y1 x0 x1)) 4]
      [(not (check-i64 4 base y0 y1 x0 x1)) 5]
      [(not (check-i64 5 base y0 y1 x0 x1)) 6]
      [(not (check-bool base y0 y1 x0 x1)) 7]
      [(not (check-exact base y0 y1 x0 x1)) 8]
      [(not (check-i64 8 base y0 y1 x0 x1)) 10]
      [(and (> rows 0) (>= width 3) (not (check-masked y0 y1 x0 x1))) 9]
      [else 0])))

(define (main) : i64
  (let
    [widths : (Array i64 14) (array 1 2 3 4 5 7 8 9 15 16 17 31 32 33)]
    [rows : (Array i64 4) (array 0 1 2 5)]
    [x0s : (Array i64 3) (array -3 0 4)]
    [y0s : (Array i64 2) (array -2 3)]
    [bases : (Array i64 2) (array 1 3)]
    [failed : i64 0]
    [w : i64 0]
    [min : i64 (- -9223372036854775807 1)]
    [max : i64 9223372036854775807]
    [empty-out : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [empty-src : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (while (and (= failed 0) (< w 14))
      (let
        [r : i64 0]
        (while (and (= failed 0) (< r 4))
          (let
            [a : i64 0]
            (while (and (= failed 0) (< a 3))
              (let
                [b : i64 0]
                (while (and (= failed 0) (< b 2))
                  (let
                    [c : i64 0]
                    (while (and (= failed 0) (< c 2))
                      (set!
                        failed
                        (check-domain
                          (array-ref bases c)
                          (array-ref y0s b)
                          (array-ref rows r)
                          (array-ref x0s a)
                          (array-ref widths w)))
                      (set! c (+ c 1))))
                  (set! b (+ b 1))))
              (set! a (+ a 1))))
          (set! r (+ r 1))))
      (set! w (+ w 1)))
    ;; A huge outer span over an empty row, and an empty outer span over a
    ;; huge row, do no per-row work.
    (map-i64 (&mut empty-out) (& empty-src) 0 min max 5 5)
    (map-i64 (&mut empty-out) (& empty-src) 0 7 7 min max)
    (if (= failed 0)
      42
      failed)))