;; A rank-2 row loop whose body calls an inlinable helper over a fixed array
;; reference (`(& (Array i64 16))`). The SPMD array views rebind the fixed array
;; to a slice view only for the inlined body; the rectangular guard's checked
;; per-row fallback (negative source stride here) must lower the same body.
;; Exits 42 when both the fast and the fallback rows match a scalar loop.
(define (lut-get [t : (& t (Array i64 16))] [k : i64]) : i64
  (array-ref t k))

(define (rect-lut
  [out : (&mut out (__tl_dyn-array i64))]
  [a : (& a (__tl_dyn-array i64))]
  [src-base : i64]
  [stride : i64]
  [t : (& t (Array i64 16))]
  [u : (& u (Array i64 16))]
  [rows : i64]
  [w : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (+
        (array-ref a (+ src-base (+ (* y stride) x)))
        (+ (array-ref t x) (lut-get u (- 15 x)))))))

(define (check-lut [src-base : i64] [stride : i64] [rows : i64] [w : i64]) : bool
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 160)]
    [got : (__tl_dyn-array i64) (__tl_make-array i64 (* rows w))]
    [t : (Array i64 16) (make-array i64 16)]
    [u : (Array i64 16) (make-array i64 16)]
    [i : i64 0]
    [ok : bool true]
    (while (< i 160)
      (set! (array-ref a i) (- (* i 7) 300))
      (+= i 1))
    (set! i 0)
    (while (< i 16)
      (set! (array-ref t i) (- (* i 13) 40))
      (set! (array-ref u i) (+ (* i 1000) 7))
      (+= i 1))
    (rect-lut (&mut got) (& a) src-base stride (& t) (& u) rows w)
    (let
      [y : i64 0]
      (while (< y rows)
        (let
          [x : i64 0]
          (while (< x w)
            (when
              (!=
                (array-ref got (+ (* y w) x))
                (+
                  (array-ref a (+ src-base (+ (* y stride) x)))
                  (+ (- (* x 13) 40) (+ (* (- 15 x) 1000) 7))))
              (set! ok false))
            (+= x 1)))
        (+= y 1)))
    ok))

(define (main) : i64
  ;; Positive stride: the hoisted rectangular fast path.
  (when (not (check-lut 3 17 5 13)) (return 1))
  ;; Negative stride: the checked per-row fallback.
  (when (not (check-lut 120 -19 5 13)) (return 2))
  ;; Full 16-wide rows on the fallback.
  (when (not (check-lut 100 -21 4 16)) (return 3))
  42)