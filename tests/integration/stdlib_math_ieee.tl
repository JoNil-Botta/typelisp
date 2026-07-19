;; Native Linux/Windows witness for allocation-free IEEE-754 math primitives.
(import stdlib.math)

(define (math-sqrt-f64-probe [value : f64])
  (:export-symbol "tl_test_math_sqrt_f64") : f64
  (math.f64-sqrt value))

(define (math-sqrt-f32-probe [value : f32])
  (:export-symbol "tl_test_math_sqrt_f32") : f32
  (math.sqrt value))

(define (main) : i64
  (let
    [negative-zero64 : f64 (math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (math.f32-from-bits (cast 0x80000000 : u32))]
    [payload64 : f64 (math.f64-from-bits (cast 0x7ff8000000001234 : u64))]
    [payload32 : f32 (math.f32-from-bits (cast 0x7fc01234 : u32))]
    [one32 : f32 1.0]
    [four32 : f32 4.0]
    [calls : i64 0]
    [once : f64
      (math.sqrt
        (begin
          (set! calls (+ calls 1))
          25.0))]
    (if (and
      (= (math.f64-to-bits negative-zero64) (cast 0x8000000000000000 : u64))
      (= (math.f32-to-bits negative-zero32) (cast 0x80000000 : u32))
      (= (math.f64-to-bits payload64) (cast 0x7ff8000000001234 : u64))
      (= (math.f32-to-bits payload32) (cast 0x7fc01234 : u32))
      (math.f64-negative-zero? (math.f64-scalbn negative-zero64 10000))
      (math.f32-negative-zero? (math.f32-scalbn negative-zero32 10000))
      (= (math.f64-to-bits (math.f64-scalbn 1.0 -1074)) (cast 1 : u64))
      (= (math.f64-to-bits (math.f64-scalbn 3.0 -1075)) (cast 2 : u64))
      (= (math.f32-to-bits (math.f32-scalbn one32 -149)) (cast 1 : u32))
      (math.f64-infinite? (math.f64-scalbn 1.0 10000))
      (math.f32-nan? (math.f32-scalbn payload32 -10000))
      (= calls 1)
      (= once 5.0)
      (= (math-sqrt-f64-probe 81.0) 9.0)
      (= (math-sqrt-f32-probe four32) (cast 2.0 : f32))
      (= (math.f64-to-bits (math.f64-sqrt 2.0)) (cast 0x3ff6a09e667f3bcd : u64))
      (=
        (math.f32-to-bits (math.f32-sqrt (math.f32-from-bits (cast 1 : u32))))
        (cast 0x1a3504f3 : u32))
      (=
        (math.f64-to-bits (math.f64-sqrt negative-zero64))
        (cast 0x8000000000000000 : u64))
      (=
        (math.f32-to-bits (math.f32-sqrt negative-zero32))
        (cast 0x80000000 : u32))
      (math.f64-infinite? (math.f64-sqrt (math.f64-positive-infinity)))
      (math.f64-nan? (math.f64-sqrt -1.0))
      (math.f32-nan? (math.f32-sqrt payload32)))
      42
      1)))