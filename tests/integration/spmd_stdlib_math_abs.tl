;; Compare nested stdlib bitcast/abs/copy-sign calls with an ordinary loop,
;; including empty ranges, both SIMD widths, tails and untouched output lanes.
(import stdlib.math)

(define (transform64 [value : f64]) : f64
  (+
    (math.f64-abs value)
    (math.f64-copy-sign (math.f64-from-bits (math.f64-to-bits value)) -1.0)))

(define (transform32 [value : f32]) : f32
  (+
    (math.f32-abs value)
    (math.f32-copy-sign
      (math.f32-from-bits (math.f32-to-bits value))
      (ann -1.0 : f32))))

(define (fill64
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (transform64 (array-ref xs i)))))

(define (fill32
  [xs : (& xs (__tl_dyn-array f32))]
  [out : (&mut out (__tl_dyn-array f32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (transform32 (array-ref xs i)))))

(define (main) : i64
  (let
    [xs64 : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [xs32 : (__tl_dyn-array f32) (__tl_make-array f32 13)]
    [out64 : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [out32 : (__tl_dyn-array f32) (__tl_make-array f32 13)]
    [sizes : (Array i64 7) (array 0 1 3 4 7 8 13)]
    [i : i64 0]
    [case-index : i64 0]
    (while (< i 13)
      (set!
        (array-ref xs64 i)
        (if (= i 0)
          -0.0
          (cast (- i 6) : f64)))
      (set!
        (array-ref xs32 i)
        (if (= i 0)
          (ann -0.0 : f32)
          (cast (- i 6) : f32)))
      (+= i 1))
    (while (< case-index (array-length sizes))
      (let
        [n : i64 (array-ref sizes case-index)]
        (set! i 0)
        (while (< i 13)
          (set! (array-ref out64 i) 99.0)
          (set! (array-ref out32 i) (ann 99.0 : f32))
          (+= i 1))
        (fill64 (& xs64) (&mut out64) n)
        (fill32 (& xs32) (&mut out32) n)
        (set! i 0)
        (while (< i 13)
          (let
            [want64 : f64
              (if (< i n)
                (transform64 (array-ref xs64 i))
                99.0)]
            [want32 : f32
              (if (< i n)
                (transform32 (array-ref xs32 i))
                (ann 99.0 : f32))]
            (when
              (!=
                (math.f64-to-bits (array-ref out64 i))
                (math.f64-to-bits want64))
              (return 1))
            (when
              (!=
                (math.f32-to-bits (array-ref out32 i))
                (math.f32-to-bits want32))
              (return 2)))
          (+= i 1)))
      (+= case-index 1))
    42))