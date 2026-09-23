;; Exact fused multiply-add (#7005). Every expected value below was produced by
;; an exact rational-arithmetic model of IEEE 754 fusedMultiplyAdd (round to
;; nearest, ties to even) that agrees with hardware FMA and libm `fma`/`fmaf` on
;; several hundred thousand vectors. `f64-mul-add` and `f32-mul-add` are pure
;; integer arithmetic, so both hosts and all optimization levels must produce
;; these bits.
(import stdlib.math)

(define (f64-is? [a : u64] [b : u64] [c : u64] [want : u64]) : bool
  (=
    (math.f64-to-bits
      (math.f64-mul-add
        (math.f64-from-bits a)
        (math.f64-from-bits b)
        (math.f64-from-bits c)))
    want))

;; NaN results have an unspecified sign and payload; only NaN-ness is checked.
(define (f64-nan? [a : u64] [b : u64] [c : u64]) : bool
  (math.f64-nan?
    (math.f64-mul-add
      (math.f64-from-bits a)
      (math.f64-from-bits b)
      (math.f64-from-bits c))))

(define (f32-is? [a : u32] [b : u32] [c : u32] [want : u32]) : bool
  (=
    (math.f32-to-bits
      (math.f32-mul-add
        (math.f32-from-bits a)
        (math.f32-from-bits b)
        (math.f32-from-bits c)))
    want))

(define (f32-nan? [a : u32] [b : u32] [c : u32]) : bool
  (math.f32-nan?
    (math.f32-mul-add
      (math.f32-from-bits a)
      (math.f32-from-bits b)
      (math.f32-from-bits c))))

(define (curated-cases-ok?) : bool
  (and
    ;; product bits lost by two roundings
    (f64-is?
      0x3ff0000000400000
      0x3ff0000000400000
      0xbff0000000000000
      0x3e20000000200000)
    ;; 0.1 * 10 - 1 is the exact residual
    (f64-is?
      0x3fb999999999999a
      0x4024000000000000
      0xbff0000000000000
      0x3c90000000000000)
    ;; tie in the product broken upward by a tiny addend
    (f64-is?
      0x3ff0000000000001
      0x3ff8000000000000
      0x3370000000000000
      0x3ff8000000000002)
    ;; tie in the product broken downward by a tiny addend
    (f64-is?
      0x3ff0000000000001
      0x3ff8000000000000
      0xb370000000000000
      0x3ff8000000000001)
    ;; exact tie rounds to even
    (f64-is?
      0x3ff0000000000001
      0x3ff8000000000000
      0x0000000000000000
      0x3ff8000000000002)
    ;; huge addend, product only sticky
    (f64-is?
      0x4008000000000000
      0x1a70000000000000
      0x5f30000000000000
      0x5f30000000000000)
    ;; huge negative power-of-two addend plus a sticky product rounds back to it
    (f64-is?
      0x4008000000000000
      0x1a70000000000000
      0xdf30000000000000
      0xdf30000000000000)
    ;; power-of-two addend minus a tiny product rounds back to it
    (f64-is?
      0xad30000000000000
      0x2d30000000000000
      0x3ff0000000000000
      0x3ff0000000000000)
    ;; overflowing product rescued by the addend
    (f64-is?
      0x7fefffffffffffff
      0x4000000000000000
      0xffefffffffffffff
      0x7fefffffffffffff)
    ;; overflow to infinity
    (f64-is?
      0x7fefffffffffffff
      0x4000000000000000
      0x7fefffffffffffff
      0x7ff0000000000000)
    ;; negative overflow
    (f64-is?
      0xffefffffffffffff
      0x4000000000000000
      0xffefffffffffffff
      0xfff0000000000000)
    ;; largest finite stays finite
    (f64-is?
      0x7fefffffffffffff
      0x3ff0000000000000
      0x0000000000000000
      0x7fefffffffffffff)
    ;; half of the smallest subnormal ties to zero
    (f64-is?
      0x0000000000000001
      0x3fe0000000000000
      0x0000000000000000
      0x0000000000000000)
    ;; just above half rounds to the smallest subnormal
    (f64-is?
      0x0000000000000001
      0x3fe0000000000000
      0x0000000000000001
      0x0000000000000002)
    ;; three halves of the smallest subnormal ties to even
    (f64-is?
      0x0000000000000001
      0x3ff8000000000000
      0x0000000000000000
      0x0000000000000002)
    ;; negative underflow keeps its sign
    (f64-is?
      0x8000000000000001
      0x3fd0000000000000
      0x0000000000000000
      0x8000000000000000)
    ;; subnormal result rounds up into the normal range
    (f64-is?
      0x000fffffffffffff
      0x3ff0000000000000
      0x0000000000000001
      0x0010000000000000)
    ;; subnormal times subnormal plus subnormal
    (f64-is?
      0x000fffffffffffff
      0x000fffffffffffff
      0x0000000000000003
      0x0000000000000003)
    ;; exact cancellation is positive zero
    (f64-is?
      0x4008000000000000
      0x4014000000000000
      0xc02e000000000000
      0x0000000000000000)
    ;; exact cancellation of a negative product is positive zero
    (f64-is?
      0xc008000000000000
      0x4014000000000000
      0x402e000000000000
      0x0000000000000000)
    ;; positive zero product plus negative zero
    (f64-is?
      0x0000000000000000
      0x4014000000000000
      0x8000000000000000
      0x0000000000000000)
    ;; negative zero product plus negative zero
    (f64-is?
      0x8000000000000000
      0x4014000000000000
      0x8000000000000000
      0x8000000000000000)
    ;; negative zero product plus positive zero
    (f64-is?
      0x8000000000000000
      0x4014000000000000
      0x0000000000000000
      0x0000000000000000)
    ;; zero product returns the addend
    (f64-is?
      0x0000000000000000
      0x4014000000000000
      0xc01d000000000000
      0xc01d000000000000)
    ;; zero product returns a subnormal addend
    (f64-is?
      0x8000000000000000
      0x4014000000000000
      0x0000000000000001
      0x0000000000000001)
    ;; infinity times zero is invalid
    (f64-nan? 0x7ff0000000000000 0x0000000000000000 0x3ff0000000000000)
    ;; zero times infinity is invalid even with an infinite addend
    (f64-nan? 0x8000000000000000 0x7ff0000000000000 0x7ff0000000000000)
    ;; infinite product plus opposite infinity is invalid
    (f64-nan? 0x7ff0000000000000 0x3ff0000000000000 0xfff0000000000000)
    ;; infinite product decides
    (f64-is?
      0x7ff0000000000000
      0xc000000000000000
      0x4014000000000000
      0xfff0000000000000)
    ;; infinite product with a matching infinite addend
    (f64-is?
      0xfff0000000000000
      0x4000000000000000
      0xfff0000000000000
      0xfff0000000000000)
    ;; finite product plus infinity
    (f64-is?
      0x7fefffffffffffff
      0x7fefffffffffffff
      0xfff0000000000000
      0xfff0000000000000)
    ;; NaN first operand
    (f64-nan? 0x7ff8000000000000 0x3ff0000000000000 0x3ff0000000000000)
    ;; NaN second operand
    (f64-nan? 0x3ff0000000000000 0x7ff8000000000005 0x3ff0000000000000)
    ;; NaN addend
    (f64-nan? 0x3ff0000000000000 0x3ff0000000000000 0xfff0000000000001)
    ;; NaN beats an invalid product
    (f64-nan? 0x7ff0000000000000 0x0000000000000000 0x7ff8000000000000)
    ;; massive cancellation keeps the low product bits
    (f64-is?
      0x3ff0000000000001
      0x3fefffffffffffff
      0xbff0000000000000
      0x3c9ffffffffffffe)
    ;; addend one bit below the product
    (f64-is?
      0x3ff0000000000001
      0x3ff0000000000001
      0x3ca0000000000000
      0x3ff0000000000003)
    ;; minimum normal squared underflows
    (f64-is?
      0x0010000000000000
      0x0010000000000000
      0x0000000000000000
      0x0000000000000000)
    ;; minimum normal squared is sticky under the smallest subnormal
    (f64-is?
      0x0010000000000000
      0x0010000000000000
      0x8000000000000001
      0x8000000000000001)
    ;; product bits lost by two roundings
    (f32-is? 0x3f800200 0x3f800200 0xbf800000 0x39000100)
    ;; 0.1 * 10 - 1 is the exact residual
    (f32-is? 0x3dcccccd 0x41200000 0xbf800000 0x32800000)
    ;; tie broken upward by a tiny addend
    (f32-is? 0x3f800001 0x3fc00000 0x0d800000 0x3fc00002)
    ;; tie broken downward by a tiny addend
    (f32-is? 0x3f800001 0x3fc00000 0x8d800000 0x3fc00001)
    ;; exact tie rounds to even
    (f32-is? 0x3f800001 0x3fc00000 0x00000000 0x3fc00002)
    ;; subnormal result whose double-rounded value would tie
    (f32-is? 0x00000003 0x3f000001 0x00000001 0x00000003)
    ;; subnormal result with a sticky product below binary64 precision
    (f32-is? 0x0d000001 0x0d000001 0x00400001 0x00400001)
    ;; overflowing product rescued by the addend
    (f32-is? 0x7f7fffff 0x40000000 0xff7fffff 0x7f7fffff)
    ;; overflow to infinity
    (f32-is? 0x7f7fffff 0x40000000 0x7f7fffff 0x7f800000)
    ;; half of the smallest subnormal ties to zero
    (f32-is? 0x00000001 0x3f000000 0x00000000 0x00000000)
    ;; three halves of the smallest subnormal ties to even
    (f32-is? 0x00000001 0x3fc00000 0x00000000 0x00000002)
    ;; negative underflow keeps its sign
    (f32-is? 0x80000001 0x3e800000 0x00000000 0x80000000)
    ;; subnormal result rounds up into the normal range
    (f32-is? 0x007fffff 0x3f800000 0x00000001 0x00800000)
    ;; exact cancellation is positive zero
    (f32-is? 0x40400000 0x40a00000 0xc1700000 0x00000000)
    ;; negative zero product plus negative zero
    (f32-is? 0x80000000 0x40a00000 0x80000000 0x80000000)
    ;; positive zero product plus negative zero
    (f32-is? 0x00000000 0x40a00000 0x80000000 0x00000000)
    ;; infinity times zero is invalid
    (f32-nan? 0x7f800000 0x00000000 0x3f800000)
    ;; infinite product plus opposite infinity is invalid
    (f32-nan? 0x7f800000 0x3f800000 0xff800000)
    ;; infinite product decides
    (f32-is? 0x7f800000 0xc0000000 0x40a00000 0xff800000)
    ;; finite product plus infinity
    (f32-is? 0x7f7fffff 0x7f7fffff 0xff800000 0xff800000)
    ;; NaN operand
    (f32-nan? 0x3f800000 0x7fc00009 0x3f800000)
    ;; huge negative power-of-two addend plus a sticky product rounds back to it
    (f32-is? 0x40400000 0x21800000 0xd3800000 0xd3800000)))

(define (lcg-next [state : u64]) : u64
  (+ (* state 6364136223846793005) 1442695040888963407))

;; Half of the draws get a mid-range exponent so that products and addends
;; overlap, cancel and tie instead of being dominated by one term.
(define (sweep-operand-f64 [state : u64]) : u64
  (if (= (bit-and state 1) 1)
    (bit-or
      (bit-and state 0x800fffffffffffff)
      (shl (+ 0x3f0 (bit-and (shr state 8) 0x1f)) 52))
    state))

(define (sweep-operand-f32 [state : u64]) : u32
  (let
    [bits : u64 (shr state 32)]
    (cast
      (if (= (bit-and state 1) 1)
        (bit-or
          (bit-and bits 0x807fffff)
          (shl (+ 0x70 (bit-and (shr state 8) 0x1f)) 23))
        bits)
      : u32)))

(define (fold [acc : u64] [value : u64]) : u64
  (+ (* (bit-xor acc value) 1099511628211) 1))

;; 20,000 pseudo-random triples per format; the checksums and NaN counts come
;; from the same generator run through the exact model.
(define (sweep-f64-ok?) : bool
  (let
    [state : u64 0x7005]
    [acc : u64 0]
    [nans : i64 0]
    [index : i64 0]
    (begin
      (while (< index 20000)
        (let
          [s1 : u64 (lcg-next state)]
          [s2 : u64 (lcg-next s1)]
          [s3 : u64 (lcg-next s2)]
          [result : f64
            (math.f64-mul-add
              (math.f64-from-bits (sweep-operand-f64 s1))
              (math.f64-from-bits (sweep-operand-f64 s2))
              (math.f64-from-bits (sweep-operand-f64 s3)))]
          (begin
            (if (math.f64-nan? result)
              (begin
                (set! nans (+ nans 1))
                (set! acc (fold acc 0)))
              (set! acc (fold acc (math.f64-to-bits result))))
            (set! state s3)
            (set! index (+ index 1)))))
      (and (= acc 0x60b0ef758dcee710) (= nans 15)))))

(define (sweep-f32-ok?) : bool
  (let
    [state : u64 0x7005]
    [acc : u64 0]
    [nans : i64 0]
    [index : i64 0]
    (begin
      (while (< index 20000)
        (let
          [s1 : u64 (lcg-next state)]
          [s2 : u64 (lcg-next s1)]
          [s3 : u64 (lcg-next s2)]
          [result : f32
            (math.f32-mul-add
              (math.f32-from-bits (sweep-operand-f32 s1))
              (math.f32-from-bits (sweep-operand-f32 s2))
              (math.f32-from-bits (sweep-operand-f32 s3)))]
          (begin
            (if (math.f32-nan? result)
              (begin
                (set! nans (+ nans 1))
                (set! acc (fold acc 0)))
              (set! acc (fold acc (cast (math.f32-to-bits result) : u64))))
            (set! state s3)
            (set! index (+ index 1)))))
      (and (= acc 0xdb9d28b9ca82f0d9) (= nans 119)))))

;; Ordinary arithmetic is never contracted into the fused operation: this
;; product loses its low bits before the subtraction, at every optimization
;; level, while the explicit call keeps them.
(define (not-contracted?) : bool
  (let
    [x : f64 (math.f64-from-bits 0x3ff0000000400000)]
    [minus-one : f64 -1.0]
    [two-roundings : f64 (+ (* x x) minus-one)]
    [fused : f64 (math.mul-add x x minus-one)]
    [x32 : f32 (math.f32-from-bits 0x3f800200)]
    [minus-one32 : f32 -1.0]
    [two-roundings32 : f32 (+ (* x32 x32) minus-one32)]
    [fused32 : f32 (math.mul-add x32 x32 minus-one32)]
    (and
      (= (math.f64-to-bits two-roundings) 0x3e20000000000000)
      (= (math.f64-to-bits fused) 0x3e20000000200000)
      (= (math.f32-to-bits two-roundings32) (cast 0x39000000 : u32))
      (= (math.f32-to-bits fused32) (cast 0x39000100 : u32)))))

(define (main) : i64
  (cond
    [(not (curated-cases-ok?)) 1]
    [(not (sweep-f64-ok?)) 2]
    [(not (sweep-f32-ok?)) 3]
    [(not (not-contracted?)) 4]
    [else 42]))