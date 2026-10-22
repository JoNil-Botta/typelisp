;; Square-root helpers preserve f64/f32 bits, including signed zero, NaN and
;; infinity. Caller-owned declarations must not capture imported intrinsics.
(import stdlib.math)

;; lint-allow: function-name-case -- intrinsic provenance fixture
(define (__tl_float_sqrt [value : f64]) : f64
  99.0)

(define (fill64
  [xs : (& xs (__tl_dyn-array f64))]
  [out : (&mut out (__tl_dyn-array f64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (math.f64-sqrt (array-ref xs i)))))

(define (fill32
  [xs : (& xs (__tl_dyn-array f32))]
  [out : (&mut out (__tl_dyn-array f32))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (math.f32-sqrt (array-ref xs i)))))

(define (main) : i64
  (let
    [xs64 : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [xs32 : (__tl_dyn-array f32) (__tl_make-array f32 13)]
    [out64 : (__tl_dyn-array f64) (__tl_make-array f64 13)]
    [out32 : (__tl_dyn-array f32) (__tl_make-array f32 13)]
    [i : i64 0]
    (when (!= (__tl_float_sqrt 4.0) 99.0) (return 1))
    (while (< i 13)
      (set!
        (array-ref xs64 i)
        (cond
          [(= i 0) -0.0]
          [(= i 1) -1.0]
          [(= i 2) (math.f64-positive-infinity)]
          [(= i 3) (math.f64-quiet-nan)]
          [else (cast (- i 4) : f64)]))
      (set!
        (array-ref xs32 i)
        (cond
          [(= i 0) (ann -0.0 : f32)]
          [(= i 1) (ann -1.0 : f32)]
          [(= i 2) (math.f32-positive-infinity)]
          [(= i 3) (math.f32-quiet-nan)]
          [else (cast (- i 4) : f32)]))
      (+= i 1))
    (fill64 (& xs64) (&mut out64) 13)
    (fill32 (& xs32) (&mut out32) 13)
    (set! i 0)
    (while (< i 13)
      (when
        (!=
          (math.f64-to-bits (array-ref out64 i))
          (math.f64-to-bits (math.f64-sqrt (array-ref xs64 i))))
        (return 2))
      (when
        (!=
          (math.f32-to-bits (array-ref out32 i))
          (math.f32-to-bits (math.f32-sqrt (array-ref xs32 i))))
        (return 3))
      (+= i 1))
    42))