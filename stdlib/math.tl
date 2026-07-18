;# Pure scalar math helpers.
;#
;# This module provides runtime-zero-dependency helpers for scalar integer and
;# IEEE-754 float values. Float bit reinterpretation uses private compiler
;# intrinsics when `feature-compiler-float-bitcast-intrinsics` is available.
;# The inactive compatibility branches keep published stage0 compilers able to
;# build a compiler that introduces those intrinsics.
;# Square root lowers through the private compiler float-sqrt intrinsic to
;# scalar SSE2 on both supported targets.
;#
;# Transcendental functions are added as freestanding implementations in
;# separate slices so Linux and Windows behavior cannot accidentally diverge.
;#
;# Runtime helpers are non-allocating and import no runtime or platform externs.
;#
;# Usage: `(import stdlib.math)`
;#
;# ```typelisp
;# (import stdlib.math)
;# (define (main) : i64
;#   (if (= (math.sqrt 81.0) 9.0)
;#     (math.i64-clamp (math.i64-abs -50) 0 42)
;#     1))
;# ```
(import stdlib.comptime)

;: Reinterpret an `f64` as its exact IEEE-754 binary64 bits.
(define (f64-to-bits [value : f64]) : u64
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_to_bits value)
    (let
      [buf : (Array f64) (make-array f64 1)]
      (begin
        (array-set! buf 0 value)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u64))))))))

;: Reinterpret IEEE-754 binary64 `bits` as an `f64`.
(define (f64-from-bits [bits : u64]) : f64
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_from_bits bits)
    (let
      [buf : (Array u64) (make-array u64 1)]
      (begin
        (array-set! buf 0 bits)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr f64))))))))

;: Reinterpret an `f32` as its exact IEEE-754 binary32 bits.
(define (f32-to-bits [value : f32]) : u32
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_to_bits value)
    (let
      [buf : (Array f32) (make-array f32 1)]
      (begin
        (array-set! buf 0 value)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u32))))))))

;: Reinterpret IEEE-754 binary32 `bits` as an `f32`.
(define (f32-from-bits [bits : u32]) : f32
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_from_bits bits)
    (let
      [buf : (Array u32) (make-array u32 1)]
      (begin
        (array-set! buf 0 bits)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr f32))))))))

;: Construct positive infinity.
(define (f64-positive-infinity) : f64
  (stdlib.math.f64-from-bits 0x7ff0000000000000))

;: Construct negative infinity.
(define (f64-negative-infinity) : f64
  (stdlib.math.f64-from-bits 0xfff0000000000000))

;: Construct a canonical quiet NaN.
(define (f64-quiet-nan) : f64
  (stdlib.math.f64-from-bits 0x7ff8000000000000))

;: Construct binary32 positive infinity.
(define (f32-positive-infinity) : f32
  (stdlib.math.f32-from-bits (cast 0x7f800000 : u32)))

;: Construct binary32 negative infinity.
(define (f32-negative-infinity) : f32
  (stdlib.math.f32-from-bits (cast 0xff800000 : u32)))

;: Construct a canonical binary32 quiet NaN.
(define (f32-quiet-nan) : f32
  (stdlib.math.f32-from-bits (cast 0x7fc00000 : u32)))

;: True when the binary64 sign bit is set, including for negative zero and NaN.
(define (f64-sign-bit? [value : f64]) : bool
  (!=
    (bit-and (stdlib.math.f64-to-bits value) 0x8000000000000000)
    (cast 0 : u64)))

;: True when the binary32 sign bit is set, including for negative zero and NaN.
(define (f32-sign-bit? [value : f32]) : bool
  (!=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x80000000 : u32))
    (cast 0 : u32)))

;: True when `value` is finite.
(define (f64-finite? [value : f64]) : bool
  (!=
    (bit-and (stdlib.math.f64-to-bits value) 0x7ff0000000000000)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is finite.
(define (f32-finite? [value : f32]) : bool
  (!=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7f800000 : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is either infinity.
(define (f64-infinite? [value : f64]) : bool
  (=
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is either infinity.
(define (f32-infinite? [value : f32]) : bool
  (=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is a NaN of either sign and any payload.
(define (f64-nan? [value : f64]) : bool
  (>
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is a NaN of either sign and any payload.
(define (f32-nan? [value : f32]) : bool
  (>
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is a normal finite binary64 number.
(define (f64-normal? [value : f64]) : bool
  (let
    [exponent : u64
      (bit-and (stdlib.math.f64-to-bits value) 0x7ff0000000000000)]
    (and
      (!= exponent (cast 0 : u64))
      (!= exponent (cast 0x7ff0000000000000 : u64)))))

;: True when `value` is a normal finite binary32 number.
(define (f32-normal? [value : f32]) : bool
  (let
    [exponent : u32
      (bit-and (stdlib.math.f32-to-bits value) (cast 0x7f800000 : u32))]
    (and (!= exponent (cast 0 : u32)) (!= exponent (cast 0x7f800000 : u32)))))

;: True when `value` is a nonzero subnormal binary64 number.
(define (f64-subnormal? [value : f64]) : bool
  (let
    [magnitude : u64
      (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)]
    (and
      (!= magnitude (cast 0 : u64))
      (< magnitude (cast 0x0010000000000000 : u64)))))

;: True when `value` is a nonzero subnormal binary32 number.
(define (f32-subnormal? [value : f32]) : bool
  (let
    [magnitude : u32
      (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (and (!= magnitude (cast 0 : u32)) (< magnitude (cast 0x00800000 : u32)))))

;: True when `value` is either binary64 signed zero.
(define (f64-signed-zero? [value : f64]) : bool
  (=
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0 : u64)))

;: True when `value` is either binary32 signed zero.
(define (f32-signed-zero? [value : f32]) : bool
  (=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0 : u32)))

;: True only for negative binary64 zero.
(define (f64-negative-zero? [value : f64]) : bool
  (= (stdlib.math.f64-to-bits value) (cast 0x8000000000000000 : u64)))

;: True only for positive binary64 zero.
(define (f64-positive-zero? [value : f64]) : bool
  (= (stdlib.math.f64-to-bits value) (cast 0 : u64)))

;: True only for negative binary32 zero.
(define (f32-negative-zero? [value : f32]) : bool
  (= (stdlib.math.f32-to-bits value) (cast 0x80000000 : u32)))

;: True only for positive binary32 zero.
(define (f32-positive-zero? [value : f32]) : bool
  (= (stdlib.math.f32-to-bits value) (cast 0 : u32)))

;: Return `magnitude` with the sign bit of `sign`.
(define (f64-copy-sign [magnitude : f64] [sign : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-or
      (bit-and (stdlib.math.f64-to-bits magnitude) 0x7fffffffffffffff)
      (bit-and (stdlib.math.f64-to-bits sign) 0x8000000000000000))))

;: Return `magnitude` with the sign bit of `sign`.
(define (f32-copy-sign [magnitude : f32] [sign : f32]) : f32
  (stdlib.math.f32-from-bits
    (bit-or
      (bit-and (stdlib.math.f32-to-bits magnitude) (cast 0x7fffffff : u32))
      (bit-and (stdlib.math.f32-to-bits sign) (cast 0x80000000 : u32)))))

;: Multiply `value` by 2^`exponent` with IEEE-754 overflow, subnormal,
;: underflow, signed-zero, infinity, and NaN behavior.
;:
;: Operation order follows musl `scalbn` at revision
;: `b306b16af15c89a04d8e0c55cac2dadbeb39c083`.
(define (f64-scalbn [value : f64] [exponent : i64]) : f64
  (let
    [y : f64 value]
    [n : i64 exponent]
    (begin
      (if (> n 1023)
        (begin
          (set! y (* y (stdlib.math.f64-from-bits 0x7fe0000000000000)))
          (set! n (- n 1023))
          (if (> n 1023)
            (begin
              (set! y (* y (stdlib.math.f64-from-bits 0x7fe0000000000000)))
              (set! n (- n 1023))
              (if (> n 1023)
                (set! n 1023)
                unit))
            unit))
        (if (< n -1022)
          (begin
            (set! y (* y (stdlib.math.f64-from-bits 0x0360000000000000)))
            (set! n (+ n 969))
            (if (< n -1022)
              (begin
                (set! y (* y (stdlib.math.f64-from-bits 0x0360000000000000)))
                (set! n (+ n 969))
                (if (< n -1022)
                  (set! n -1022)
                  unit))
              unit))
          unit))
      (* y (stdlib.math.f64-from-bits (shl (cast (+ 1023 n) : u64) 52))))))

;: Binary32 `scalbn`, following musl `scalbnf` at revision
;: `b306b16af15c89a04d8e0c55cac2dadbeb39c083`.
(define (f32-scalbn [value : f32] [exponent : i64]) : f32
  (let
    [y : f32 value]
    [n : i64 exponent]
    (begin
      (if (> n 127)
        (begin
          (set! y (* y (stdlib.math.f32-from-bits (cast 0x7f000000 : u32))))
          (set! n (- n 127))
          (if (> n 127)
            (begin
              (set! y (* y (stdlib.math.f32-from-bits (cast 0x7f000000 : u32))))
              (set! n (- n 127))
              (if (> n 127)
                (set! n 127)
                unit))
            unit))
        (if (< n -126)
          (begin
            (set! y (* y (stdlib.math.f32-from-bits (cast 0x0c800000 : u32))))
            (set! n (+ n 102))
            (if (< n -126)
              (begin
                (set!
                  y
                  (* y (stdlib.math.f32-from-bits (cast 0x0c800000 : u32))))
                (set! n (+ n 102))
                (if (< n -126)
                  (set! n -126)
                  unit))
              unit))
          unit))
      (* y (stdlib.math.f32-from-bits (shl (cast (+ 127 n) : u32) 23))))))

;; The trigonometric implementation below is derived from the musl/fdlibm
;; sources pinned in MATH_LICENSES.md. Keep the constants as exact IEEE-754
;; bit patterns and preserve the written operation order: the polynomial error
;; bounds and compensated argument reduction depend on both.
(defstruct MathTrigReduction
  (quadrant i64)
  (hi f64)
  (lo f64))

;; 1,584 binary digits (396 hexadecimal digits) of 2/pi, split into 24-bit
;; limbs. Binary64 needs at most limb 46 for its largest finite exponent; the
;; complete 66-limb fdlibm double table is retained so reducer recomputation
;; always has headroom. A lookup function keeps the constants in code instead
;; of creating a heap-allocated module-global array during startup.
(define (math-trig-two-over-pi-limb [index : i64]) : u32
  (cond
    [(= index 0) 0xA2F983]
    [(= index 1) 0x6E4E44]
    [(= index 2) 0x1529FC]
    [(= index 3) 0x2757D1]
    [(= index 4) 0xF534DD]
    [(= index 5) 0xC0DB62]
    [(= index 6) 0x95993C]
    [(= index 7) 0x439041]
    [(= index 8) 0xFE5163]
    [(= index 9) 0xABDEBB]
    [(= index 10) 0xC561B7]
    [(= index 11) 0x246E3A]
    [(= index 12) 0x424DD2]
    [(= index 13) 0xE00649]
    [(= index 14) 0x2EEA09]
    [(= index 15) 0xD1921C]
    [(= index 16) 0xFE1DEB]
    [(= index 17) 0x1CB129]
    [(= index 18) 0xA73EE8]
    [(= index 19) 0x8235F5]
    [(= index 20) 0x2EBB44]
    [(= index 21) 0x84E99C]
    [(= index 22) 0x7026B4]
    [(= index 23) 0x5F7E41]
    [(= index 24) 0x3991D6]
    [(= index 25) 0x398353]
    [(= index 26) 0x39F49C]
    [(= index 27) 0x845F8B]
    [(= index 28) 0xBDF928]
    [(= index 29) 0x3B1FF8]
    [(= index 30) 0x97FFDE]
    [(= index 31) 0x05980F]
    [(= index 32) 0xEF2F11]
    [(= index 33) 0x8B5A0A]
    [(= index 34) 0x6D1F6D]
    [(= index 35) 0x367ECF]
    [(= index 36) 0x27CB09]
    [(= index 37) 0xB74F46]
    [(= index 38) 0x3F669E]
    [(= index 39) 0x5FEA2D]
    [(= index 40) 0x7527BA]
    [(= index 41) 0xC7EBE5]
    [(= index 42) 0xF17B3D]
    [(= index 43) 0x0739F7]
    [(= index 44) 0x8A5292]
    [(= index 45) 0xEA6BFB]
    [(= index 46) 0x5FB11F]
    [(= index 47) 0x8D5D08]
    [(= index 48) 0x560330]
    [(= index 49) 0x46FC7B]
    [(= index 50) 0x6BABF0]
    [(= index 51) 0xCFBC20]
    [(= index 52) 0x9AF436]
    [(= index 53) 0x1DA9E3]
    [(= index 54) 0x91615E]
    [(= index 55) 0xE61B08]
    [(= index 56) 0x659985]
    [(= index 57) 0x5F14A0]
    [(= index 58) 0x68408D]
    [(= index 59) 0xFFD880]
    [(= index 60) 0x4D7327]
    [(= index 61) 0x310606]
    [(= index 62) 0x1556CA]
    [(= index 63) 0x73A8C9]
    [(= index 64) 0x60E27B]
    [(= index 65) 0xC08C6B]
    [else 0]))

;; pi/2 split into non-overlapping 24-bit pieces. As above, the lookup avoids
;; startup allocation for a global fixed array.
(define (math-trig-pi-over-two-piece [index : i64]) : f64
  (cond
    [(= index 0) (stdlib.math.f64-from-bits 0x3FF921FB40000000)]
    [(= index 1) (stdlib.math.f64-from-bits 0x3E74442D00000000)]
    [(= index 2) (stdlib.math.f64-from-bits 0x3CF8469880000000)]
    [(= index 3) (stdlib.math.f64-from-bits 0x3B78CC5160000000)]
    [(= index 4) (stdlib.math.f64-from-bits 0x39F01B8380000000)]
    [(= index 5) (stdlib.math.f64-from-bits 0x387A252040000000)]
    [(= index 6) (stdlib.math.f64-from-bits 0x36E3822280000000)]
    [else (stdlib.math.f64-from-bits 0x3569F31D00000000)]))

(define (math-trig-input-limb [index : i64] [x0 : f64] [x1 : f64] [x2 : f64]) : f64
  (if (= index 0)
    x0
    (if (= index 1)
      x1
      x2)))

;; Payne-Hanek-style reduction from musl __rem_pio2_large.c. The input is a
;; positive significand split into one (binary32) or three (binary64) 24-bit
;; limbs. Only precisions 0 (one-term float remainder) and 1 (two-term double
;; remainder) are needed here.
(define (math-trig-rem-pio2-large
  [x0 : f64]
  [x1 : f64]
  [x2 : f64]
  [e0 : i64]
  [nx : i64]
  [precision : i64]) : MathTrigReduction
  (let
    [iq : (Array i64 20) (init)]
    [f : (Array f64 20) (init)]
    [fq : (Array f64 20) (init)]
    [q : (Array f64 20) (init)]
    [jk : i64
      (if (= precision 0)
        3
        4)]
    [jp : i64 jk]
    [jx : i64 (- nx 1)]
    [jv : i64 (/ (- e0 3) 24)]
    [q0 : i64 0]
    [jz : i64 0]
    [carry : i64 0]
    [n : i64 0]
    [ih : i64 0]
    [i : i64 0]
    [j : i64 0]
    [k : i64 0]
    [m : i64 0]
    [z : f64 0.0]
    [fw : f64 0.0]
    [need-recompute : bool true]
    (begin
      (if (< jv 0)
        (set! jv 0)
        unit)
      (set! q0 (- e0 (* 24 (+ jv 1))))
      ;; f[0..jx+jk] selects the exponent-local window of the 2/pi table.
      (set! j (- jv jx))
      (set! m (+ jx jk))
      (set! i 0)
      (while (<= i m)
        (begin
          (array-set!
            f
            i
            (if (< j 0)
              0.0
              (cast (math-trig-two-over-pi-limb j) : f64)))
          (set! i (+ i 1))
          (set! j (+ j 1))))
      ;; q is the local convolution of the significand and 2/pi limbs.
      (set! i 0)
      (while (<= i jk)
        (begin
          (set! fw 0.0)
          (set! j 0)
          (while (<= j jx)
            (begin
              (set!
                fw
                (+
                  fw
                  (*
                    (math-trig-input-limb j x0 x1 x2)
                    (array-ref f (- (+ jx i) j)))))
              (set! j (+ j 1))))
          (array-set! q i fw)
          (set! i (+ i 1))))
      (set! jz jk)
      (while need-recompute
        (begin
          ;; Distill q into base-2^24 integer limbs in reverse order.
          (set! i 0)
          (set! j jz)
          (set! z (array-ref q jz))
          (while (> j 0)
            (begin
              (set!
                fw
                (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
              (array-set! iq i (cast (- z (* 16777216.0 fw)) : i64))
              (set! z (+ (array-ref q (- j 1)) fw))
              (set! i (+ i 1))
              (set! j (- j 1))))
          ;; Extract N mod 8 and the fractional product.
          (set! z (stdlib.math.f64-scalbn z q0))
          (set! z (- z (* 8.0 (cast (cast (* z 0.125) : i64) : f64))))
          (set! n (cast z : i64))
          (set! z (- z (cast n : f64)))
          (set! ih 0)
          (cond
            [(> q0 0)
              (begin
                (set! i (shr (array-ref iq (- jz 1)) (- 24 q0)))
                (set! n (+ n i))
                (array-set!
                  iq
                  (- jz 1)
                  (- (array-ref iq (- jz 1)) (shl i (- 24 q0))))
                (set! ih (shr (array-ref iq (- jz 1)) (- 23 q0))))]
            [(= q0 0) (set! ih (shr (array-ref iq (- jz 1)) 23))]
            [(>= z 0.5) (set! ih 2)]
            [else unit])
          ;; Fold q > 1/2 to 1-q and remember the remainder sign.
          (if (> ih 0)
            (begin
              (set! n (+ n 1))
              (set! carry 0)
              (set! i 0)
              (while (< i jz)
                (begin
                  (set! j (array-ref iq i))
                  (if (= carry 0)
                    (if (!= j 0)
                      (begin
                        (set! carry 1)
                        (array-set! iq i (- 0x1000000 j)))
                      unit)
                    (array-set! iq i (- 0xffffff j)))
                  (set! i (+ i 1))))
              (if (= q0 1)
                (array-set!
                  iq
                  (- jz 1)
                  (bit-and (array-ref iq (- jz 1)) 0x7fffff))
                (if (= q0 2)
                  (array-set!
                    iq
                    (- jz 1)
                    (bit-and (array-ref iq (- jz 1)) 0x3fffff))
                  unit))
              (if (= ih 2)
                (begin
                  (set! z (- 1.0 z))
                  (if (!= carry 0)
                    (set! z (- z (stdlib.math.f64-scalbn 1.0 q0)))
                    unit))
                unit))
            unit)
          ;; Exact cancellation can consume the current table window. Extend
          ;; the convolution just far enough and distill it again.
          (set! need-recompute false)
          (if (= z 0.0)
            (begin
              (set! j 0)
              (set! i (- jz 1))
              (while (>= i jk)
                (begin
                  (set! j (bit-or j (array-ref iq i)))
                  (set! i (- i 1))))
              (if (= j 0)
                (begin
                  (set! k 1)
                  (while (= (array-ref iq (- jk k)) 0)
                    (set! k (+ k 1)))
                  (set! i (+ jz 1))
                  (while (<= i (+ jz k))
                    (begin
                      (array-set!
                        f
                        (+ jx i)
                        (cast (math-trig-two-over-pi-limb (+ jv i)) : f64))
                      (set! fw 0.0)
                      (set! j 0)
                      (while (<= j jx)
                        (begin
                          (set!
                            fw
                            (+
                              fw
                              (*
                                (math-trig-input-limb j x0 x1 x2)
                                (array-ref f (- (+ jx i) j)))))
                          (set! j (+ j 1))))
                      (array-set! q i fw)
                      (set! i (+ i 1))))
                  (set! jz (+ jz k))
                  (set! need-recompute true))
                unit))
            unit)))
      ;; Normalize the final fractional limbs.
      (if (= z 0.0)
        (begin
          (set! jz (- jz 1))
          (set! q0 (- q0 24))
          (while (= (array-ref iq jz) 0)
            (begin
              (set! jz (- jz 1))
              (set! q0 (- q0 24)))))
        (begin
          (set! z (stdlib.math.f64-scalbn z (- 0 q0)))
          (if (>= z 16777216.0)
            (begin
              (set!
                fw
                (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
              (array-set! iq jz (cast (- z (* 16777216.0 fw)) : i64))
              (set! jz (+ jz 1))
              (set! q0 (+ q0 24))
              (array-set! iq jz (cast fw : i64)))
            (array-set! iq jz (cast z : i64)))))
      ;; Convert integer limbs back to scaled floating values.
      (set! fw (stdlib.math.f64-scalbn 1.0 q0))
      (set! i jz)
      (while (>= i 0)
        (begin
          (array-set! q i (* fw (cast (array-ref iq i) : f64)))
          (set! fw (* fw 0.000000059604644775390625))
          (set! i (- i 1))))
      ;; Multiply by the split pi/2 table.
      (set! i jz)
      (while (>= i 0)
        (begin
          (set! fw 0.0)
          (set! k 0)
          (while (and (<= k jp) (<= k (- jz i)))
            (begin
              (set!
                fw
                (+ fw (* (math-trig-pi-over-two-piece k) (array-ref q (+ i k)))))
              (set! k (+ k 1))))
          (array-set! fq (- jz i) fw)
          (set! i (- i 1))))
      ;; Compress to one term for binary32 or a compensated two-term result
      ;; for binary64.
      (set! fw 0.0)
      (set! i jz)
      (while (>= i 0)
        (begin
          (set! fw (+ fw (array-ref fq i)))
          (set! i (- i 1))))
      (if (= precision 0)
        (MathTrigReduction
          (bit-and n 7)
          (if (= ih 0)
            fw
            (- 0.0 fw))
          0.0)
        (let
          [head : f64 fw]
          [tail : f64 (- (array-ref fq 0) fw)]
          (begin
            (set! i 1)
            (while (<= i jz)
              (begin
                (set! tail (+ tail (array-ref fq i)))
                (set! i (+ i 1))))
            (MathTrigReduction
              (bit-and n 7)
              (if (= ih 0)
                head
                (- 0.0 head))
              (if (= ih 0)
                tail
                (- 0.0 tail)))))))))

(define (math-trig-f64-constant [bits : u64]) : f64
  (stdlib.math.f64-from-bits bits))

(define (math-trig-truncate-low-word [value : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-and (stdlib.math.f64-to-bits value) (cast 0xffffffff00000000 : u64))))

;; Binary64 pi/2 reduction. The medium path uses three compensated 33-bit
;; pieces; the large path decomposes the significand into 24-bit limbs for the
;; shared Payne-Hanek reducer above.
(define (math-trig-rem-pio2-f64 [value : f64]) : MathTrigReduction
  (let
    [bits : u64 (stdlib.math.f64-to-bits value)]
    [ix : u64 (bit-and (shr bits 32) (cast 0x7fffffff : u64))]
    [fn : f64 0.0]
    [n : i64 0]
    [r : f64 0.0]
    [w : f64 0.0]
    [t : f64 0.0]
    [hi : f64 0.0]
    [ex : i64 0]
    [ey : i64 0]
    (if (< ix (cast 0x413921fb : u64))
      (begin
        ;; rint(value * 2/pi) for round-to-nearest without an extern.
        (set!
          fn
          (+
            (* value (math-trig-f64-constant (cast 0x3FE45F306DC9C883 : u64)))
            (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set!
          fn
          (- fn (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set! n (cast fn : i64))
        (set!
          r
          (-
            value
            (* fn (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
        (set! w (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64))))
        (if (<
          (- r w)
          (- 0.0 (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64))))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set!
              r
              (-
                value
                (* fn (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
            (set!
              w
              (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64)))))
          (if (>
            (- r w)
            (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64)))
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set!
                r
                (-
                  value
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
              (set!
                w
                (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64)))))
            unit))
        (set! hi (- r w))
        (set! ex (cast (shr ix 20) : i64))
        (set!
          ey
          (cast
            (bit-and (shr (stdlib.math.f64-to-bits hi) 52) (cast 0x7ff : u64))
            : i64))
        (if (> (- ex ey) 16)
          (begin
            (set! t r)
            (set!
              w
              (* fn (math-trig-f64-constant (cast 0x3DD0B4611A600000 : u64))))
            (set! r (- t w))
            (set!
              w
              (-
                (* fn (math-trig-f64-constant (cast 0x3BA3198A2E037073 : u64)))
                (- (- t r) w)))
            (set! hi (- r w))
            (set!
              ey
              (cast
                (bit-and
                  (shr (stdlib.math.f64-to-bits hi) 52)
                  (cast 0x7ff : u64))
                : i64))
            (if (> (- ex ey) 49)
              (begin
                (set! t r)
                (set!
                  w
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3BA3198A2E000000 : u64))))
                (set! r (- t w))
                (set!
                  w
                  (-
                    (*
                      fn
                      (math-trig-f64-constant (cast 0x397B839A252049C1 : u64)))
                    (- (- t r) w)))
                (set! hi (- r w)))
              unit))
          unit)
        (MathTrigReduction n hi (- (- r hi) w)))
      (if (>= ix (cast 0x7ff00000 : u64))
        (let
          [nan : f64 (- value value)]
          (MathTrigReduction 0 nan nan))
        (let
          [magnitude : u64 (bit-and bits (cast 0x000fffffffffffff : u64))]
          [normalized : u64 (bit-or magnitude (cast 0x4160000000000000 : u64))]
          [z : f64 (stdlib.math.f64-from-bits normalized)]
          [x0 : f64 0.0]
          [x1 : f64 0.0]
          [x2 : f64 0.0]
          [nx : i64 3]
          [large : MathTrigReduction (MathTrigReduction 0 0.0 0.0)]
          (begin
            (set! x0 (cast (cast z : i64) : f64))
            (set! z (* (- z x0) 16777216.0))
            (set! x1 (cast (cast z : i64) : f64))
            (set! z (* (- z x1) 16777216.0))
            (set! x2 z)
            (if (= x2 0.0)
              (begin
                (set! nx 2)
                (if (= x1 0.0)
                  (set! nx 1)
                  unit))
              unit)
            (set!
              large
              (math-trig-rem-pio2-large
                x0
                x1
                x2
                (- (cast (shr ix 20) : i64) (+ 0x3ff 23))
                nx
                1))
            (if (!=
              (bit-and bits (cast 0x8000000000000000 : u64))
              (cast 0 : u64))
              (MathTrigReduction
                (- 0 (struct-get large quadrant))
                (- 0.0 (struct-get large hi))
                (- 0.0 (struct-get large lo)))
              large)))))))

;; Binary32 reduction keeps all arithmetic in binary64, then returns the
;; one-term remainder expected by the float kernels.
(define (math-trig-rem-pio2-f32 [value : f32]) : MathTrigReduction
  (let
    [bits : u32 (stdlib.math.f32-to-bits value)]
    [ix : u32 (bit-and bits (cast 0x7fffffff : u32))]
    [wide : f64 (cast value : f64)]
    [fn : f64 0.0]
    [n : i64 0]
    [remainder : f64 0.0]
    (if (< ix (cast 0x4dc90fdb : u32))
      (begin
        (set!
          fn
          (+
            (* wide (math-trig-f64-constant (cast 0x3FE45F306DC9C883 : u64)))
            (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set!
          fn
          (- fn (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set! n (cast fn : i64))
        (set!
          remainder
          (-
            (-
              wide
              (* fn (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
            (* fn (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64)))))
        (if (<
          remainder
          (- 0.0 (math-trig-f64-constant (cast 0x3FE921FB60000000 : u64))))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set!
              remainder
              (-
                (-
                  wide
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
                (* fn (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64))))))
          (if (>
            remainder
            (math-trig-f64-constant (cast 0x3FE921FB60000000 : u64)))
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set!
                remainder
                (-
                  (-
                    wide
                    (*
                      fn
                      (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64))))))
            unit))
        (MathTrigReduction n remainder 0.0))
      (if (>= ix (cast 0x7f800000 : u32))
        (let
          [nan : f64 (- wide wide)]
          (MathTrigReduction 0 nan 0.0))
        (let
          [sign : bool
            (!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))]
          [e0 : i64 (- (cast (shr ix 23) : i64) (+ 0x7f 23))]
          [scaled-bits : u32 (- ix (shl (cast e0 : u32) 23))]
          [large : MathTrigReduction
            (math-trig-rem-pio2-large
              (cast (stdlib.math.f32-from-bits scaled-bits) : f64)
              0.0
              0.0
              e0
              1
              0)]
          (if sign
            (MathTrigReduction
              (- 0 (struct-get large quadrant))
              (- 0.0 (struct-get large hi))
              0.0)
            large))))))

;; Polynomial kernels on the reduced interval [-pi/4, pi/4].
(define (math-trig-kernel-sin-f64 [x : f64] [tail : f64] [tail-present : bool]) : f64
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0x3F8111111110F8A6 : u64))
        (*
          z
          (+
            (math-trig-f64-constant (cast 0xBF2A01A019C161D5 : u64))
            (* z (math-trig-f64-constant (cast 0x3EC71DE357B1FE7D : u64)))))
        (*
          z
          w
          (+
            (math-trig-f64-constant (cast 0xBE5AE5E68A2B9CEB : u64))
            (* z (math-trig-f64-constant (cast 0x3DE5D93A5ACFD57C : u64))))))]
    [v : f64 (* z x)]
    (if tail-present
      (-
        x
        (-
          (- (* z (- (* 0.5 tail) (* v r))) tail)
          (* v (math-trig-f64-constant (cast 0xBFC5555555555549 : u64)))))
      (+
        x
        (*
          v
          (+ (math-trig-f64-constant (cast 0xBFC5555555555549 : u64)) (* z r)))))))

(define (math-trig-kernel-cos-f64 [x : f64] [tail : f64]) : f64
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (*
          z
          (+
            (math-trig-f64-constant (cast 0x3FA555555555554C : u64))
            (*
              z
              (+
                (math-trig-f64-constant (cast 0xBF56C16C16C15177 : u64))
                (* z (math-trig-f64-constant (cast 0x3EFA01A019CB1590 : u64)))))))
        (*
          w
          w
          (+
            (math-trig-f64-constant (cast 0xBE927E4F809C52AD : u64))
            (*
              z
              (+
                (math-trig-f64-constant (cast 0x3E21EE9EBDB4B1C4 : u64))
                (* z (math-trig-f64-constant (cast 0xBDA8FAE9BE8838D4 : u64))))))))]
    [half-z : f64 (* 0.5 z)]
    [base : f64 (- 1.0 half-z)]
    (+ base (+ (- (- 1.0 base) half-z) (- (* z r) (* x tail))))))

(define (math-trig-kernel-tan-f64
  [input-x : f64]
  [input-tail : f64]
  [odd : bool]) : f64
  (let
    [x : f64 input-x]
    [tail : f64 input-tail]
    [high : u64
      (bit-and (shr (stdlib.math.f64-to-bits x) 32) (cast 0x7fffffff : u64))]
    [big : bool (>= high (cast 0x3FE59428 : u64))]
    [negative : bool (stdlib.math.f64-sign-bit? x)]
    [z : f64 0.0]
    [w : f64 0.0]
    [r : f64 0.0]
    [v : f64 0.0]
    [s : f64 0.0]
    (begin
      (if big
        (begin
          (if negative
            (begin
              (set! x (- 0.0 x))
              (set! tail (- 0.0 tail)))
            unit)
          (set!
            x
            (+
              (- (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64)) x)
              (- (math-trig-f64-constant (cast 0x3C81A62633145C07 : u64)) tail)))
          (set! tail 0.0))
        unit)
      (set! z (* x x))
      (set! w (* z z))
      (set!
        r
        (+
          (math-trig-f64-constant (cast 0x3FC111111110FE7A : u64))
          (*
            w
            (+
              (math-trig-f64-constant (cast 0x3F9664F48406D637 : u64))
              (*
                w
                (+
                  (math-trig-f64-constant (cast 0x3F6D6D22C9560328 : u64))
                  (*
                    w
                    (+
                      (math-trig-f64-constant (cast 0x3F4344D8F2F26501 : u64))
                      (*
                        w
                        (+
                          (math-trig-f64-constant
                            (cast 0x3F147E88A03792A6 : u64))
                          (*
                            w
                            (math-trig-f64-constant
                              (cast 0xBEF375CBDB605373 : u64)))))))))))))
      (set!
        v
        (*
          z
          (+
            (math-trig-f64-constant (cast 0x3FABA1BA1BB341FE : u64))
            (*
              w
              (+
                (math-trig-f64-constant (cast 0x3F8226E3E96E8493 : u64))
                (*
                  w
                  (+
                    (math-trig-f64-constant (cast 0x3F57DBC8FEE08315 : u64))
                    (*
                      w
                      (+
                        (math-trig-f64-constant (cast 0x3F3026F71A8D1068 : u64))
                        (*
                          w
                          (+
                            (math-trig-f64-constant
                              (cast 0x3F12B80F32F0A7E9 : u64))
                            (*
                              w
                              (math-trig-f64-constant
                                (cast 0x3EFB2A7074BF7AD4 : u64))))))))))))))
      (set! s (* z x))
      (set!
        r
        (+
          tail
          (* z (+ (* s (+ r v)) tail))
          (* s (math-trig-f64-constant (cast 0x3FD5555555555563 : u64)))))
      (set! w (+ x r))
      (if big
        (let
          [sign : f64
            (if odd
              -1.0
              1.0)]
          [result : f64 (- sign (* 2.0 (+ x (- r (/ (* w w) (+ w sign))))))]
          (if negative
            (- 0.0 result)
            result))
        (if (not odd)
          w
          (let
            [w0 : f64 (math-trig-truncate-low-word w)]
            [correction : f64 (- r (- w0 x))]
            [reciprocal : f64 (/ -1.0 w)]
            [a0 : f64 (math-trig-truncate-low-word reciprocal)]
            (+ a0 (* reciprocal (+ 1.0 (+ (* a0 w0) (* a0 correction)))))))))))

(define (math-trig-kernel-sin-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0xBF2A00F9E2CAE774 : u64))
        (* z (math-trig-f64-constant (cast 0x3EC6CD878C3B46A7 : u64))))]
    [s : f64 (* z x)]
    (cast
      (+
        (+
          x
          (*
            s
            (+
              (math-trig-f64-constant (cast 0xBFC5555554CBAC77 : u64))
              (* z (math-trig-f64-constant (cast 0x3F811110896EFBB2 : u64))))))
        (* s w r))
      : f32)))

(define (math-trig-kernel-cos-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0xBF56C087E80F1E27 : u64))
        (* z (math-trig-f64-constant (cast 0x3EF99342E0EE5069 : u64))))]
    (cast
      (+
        (+
          (+ 1.0 (* z (math-trig-f64-constant (cast 0xBFDFFFFFFD0C5E81 : u64))))
          (* w (math-trig-f64-constant (cast 0x3FA55553E1053A42 : u64))))
        (* (* w z) r))
      : f32)))

(define (math-trig-kernel-tan-f32 [x : f64] [odd : bool]) : f32
  (let
    [z : f64 (* x x)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0x3F685DADFCECF44E : u64))
        (* z (math-trig-f64-constant (cast 0x3F8362B9BF971BCD : u64))))]
    [t : f64
      (+
        (math-trig-f64-constant (cast 0x3FAB54C91D865AFE : u64))
        (* z (math-trig-f64-constant (cast 0x3F991DF3908C33CE : u64))))]
    [w : f64 (* z z)]
    [s : f64 (* z x)]
    [u : f64
      (+
        (math-trig-f64-constant (cast 0x3FD5554D3418C99F : u64))
        (* z (math-trig-f64-constant (cast 0x3FC112FD38999F72 : u64))))]
    [result : f64 (+ (+ x (* s u)) (* (* s w) (+ t (* w r))))]
    (cast
      (if odd
        (/ -1.0 result)
        result)
      : f32)))

;: Return sin(value) for every finite binary64 input.
;:
;: This allocation-free, extern-free implementation follows musl/fdlibm and
;: has a maximum error below 1.5 ULP in round-to-nearest mode.
(define (f64-sin [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e500000 : u64))
        value
        (math-trig-kernel-sin-f64 value 0.0 false))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0)
              (math-trig-kernel-sin-f64
                (struct-get reduced hi)
                (struct-get reduced lo)
                true)]
            [(= quadrant 1)
              (math-trig-kernel-cos-f64
                (struct-get reduced hi)
                (struct-get reduced lo))]
            [(= quadrant 2)
              (-
                0.0
                (math-trig-kernel-sin-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)
                  true))]
            [else
              (-
                0.0
                (math-trig-kernel-cos-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)))]))))))

;: Return cos(value) for every finite binary64 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f64-cos [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e46a09e : u64))
        1.0
        (math-trig-kernel-cos-f64 value 0.0))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0)
              (math-trig-kernel-cos-f64
                (struct-get reduced hi)
                (struct-get reduced lo))]
            [(= quadrant 1)
              (-
                0.0
                (math-trig-kernel-sin-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)
                  true))]
            [(= quadrant 2)
              (-
                0.0
                (math-trig-kernel-cos-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)))]
            [else
              (math-trig-kernel-sin-f64
                (struct-get reduced hi)
                (struct-get reduced lo)
                true)]))))))

;: Return tan(value) for every finite binary64 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f64-tan [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e400000 : u64))
        value
        (math-trig-kernel-tan-f64 value 0.0 false))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          (math-trig-kernel-tan-f64
            (struct-get reduced hi)
            (struct-get reduced lo)
            (!= (bit-and (struct-get reduced quadrant) 1) 0)))))))

;: Return sin(value) for every finite binary32 input.
;:
;: Reduction and kernels follow musl/fdlibm and stay below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-sin [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        value
        (math-trig-kernel-sin-f32 (cast value : f64)))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-sin-f32 (struct-get reduced hi))]
            [(= quadrant 1) (math-trig-kernel-cos-f32 (struct-get reduced hi))]
            [(= quadrant 2)
              (math-trig-kernel-sin-f32 (- 0.0 (struct-get reduced hi)))]
            [else
              (-
                (cast 0.0 : f32)
                (math-trig-kernel-cos-f32 (struct-get reduced hi)))]))))))

;: Return cos(value) for every finite binary32 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-cos [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        (cast 1.0 : f32)
        (math-trig-kernel-cos-f32 (cast value : f64)))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-cos-f32 (struct-get reduced hi))]
            [(= quadrant 1)
              (math-trig-kernel-sin-f32 (- 0.0 (struct-get reduced hi)))]
            [(= quadrant 2)
              (-
                (cast 0.0 : f32)
                (math-trig-kernel-cos-f32 (struct-get reduced hi)))]
            [else (math-trig-kernel-sin-f32 (struct-get reduced hi))]))))))

;: Return tan(value) for every finite binary32 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-tan [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        value
        (math-trig-kernel-tan-f32 (cast value : f64) false))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          (math-trig-kernel-tan-f32
            (struct-get reduced hi)
            (!= (bit-and (struct-get reduced quadrant) 1) 0)))))))

;: Return the absolute value of an `i64`.
;:
;: The positive magnitude of the most-negative `i64` is not representable, so
;: that value is returned unchanged. Use `i64-abs-or` to choose a fallback.
(define (i64-abs [value : i64]) : i64
  (stdlib.math.i64-abs-or value value))

;: Return the absolute value of an `i64`, or `fallback` for the most-negative
;: `i64` whose positive magnitude is not representable.
(define (i64-abs-or [value : i64] [fallback : i64]) : i64
  (if (= value -9223372036854775808)
    fallback
    (if (< value 0)
      (- 0 value)
      value)))

;: Return the absolute value of an `f64` or `f32` expression.
;:
;: The expression is evaluated once and then checked by ordinary float
;: arithmetic rules.
(defmacro (abs [value : Expr]) : Expr
  `(let
    [__math_abs_value ,value]
    (if (< __math_abs_value 0.0)
      (- 0.0 __math_abs_value)
      __math_abs_value)))

;: Return the smaller `i64` value.
(define (i64-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

;: Return the larger `i64` value.
(define (i64-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `i64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (i64-clamp [value : i64] [a : i64] [b : i64]) : i64
  (let
    [lo : i64 (stdlib.math.i64-min a b)]
    [hi : i64 (stdlib.math.i64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (i64-negative? [value : i64]) : bool
  (< value 0))

;: True when `value` is equal to zero.
(define (i64-zero? [value : i64]) : bool
  (= value 0))

;: True when `value` is greater than zero.
(define (i64-positive? [value : i64]) : bool
  (> value 0))

;: Return the absolute value of an `f64`.
(define (f64-abs [value : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)))

;: Return the absolute value of an `f32`.
(define (f32-abs [value : f32]) : f32
  (stdlib.math.f32-from-bits
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))))

;: Return the scalar SSE2 square root of an `f64`.
;:
;: Under the default MXCSR round-to-nearest, ties-to-even mode, positive finite
;: normal and subnormal inputs are correctly rounded. Positive and negative
;: zero retain their sign, positive infinity is unchanged, negative finite
;: values and negative infinity produce NaN, and NaN inputs produce NaN.
;: Signaling-NaN payload, quieting, and floating-point exception details follow
;: the hardware and are not part of this public contract.
(define (f64-sqrt [value : f64]) : f64
  (__tl_float_sqrt value))

;: Return the scalar SSE2 square root of an `f32`.
;:
;: Behavior matches `f64-sqrt` at binary32 precision and follows the active
;: MXCSR rounding mode.
(define (f32-sqrt [value : f32]) : f32
  (__tl_float_sqrt value))

;: Return the square root of an `f64` or `f32` expression, preserving its type.
;:
;: The expression is evaluated exactly once. Other operand types are rejected
;: with a compile-time diagnostic.
(defmacro (sqrt [value : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type value))
    ["f64" `(stdlib.math.f64-sqrt ,value)]
    ["f32" `(stdlib.math.f32-sqrt ,value)]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.sqrt: expected f64 or f32, found "
          (type-kind (comptime.expr-type value))))]))

;: Return the smaller `f64` value according to TypeLisp scalar comparison.
(define (f64-min [a : f64] [b : f64]) : f64
  (if (< a b)
    a
    b))

;: Return the larger `f64` value according to TypeLisp scalar comparison.
(define (f64-max [a : f64] [b : f64]) : f64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `f64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (f64-clamp [value : f64] [a : f64] [b : f64]) : f64
  (let
    [lo : f64 (stdlib.math.f64-min a b)]
    [hi : f64 (stdlib.math.f64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (f64-negative? [value : f64]) : bool
  (< value 0.0))

;: True when `value` is equal to zero.
(define (f64-zero? [value : f64]) : bool
  (= value 0.0))

;: True when `value` is greater than zero.
(define (f64-positive? [value : f64]) : bool
  (> value 0.0))

(test
  math-trig-reduction-and-special-values
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [pi : f64 (stdlib.math.f64-from-bits 0x400921fb54442d18)]
    [max64 : f64 (stdlib.math.f64-from-bits 0x7fefffffffffffff)]
    [max32 : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [medium : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 pi)]
    [large64 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 max64)]
    [large32 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f32 max32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    (begin
      (if (and
        (= (bit-and (struct-get medium quadrant) 3) 2)
        (<= (stdlib.math.f64-abs (struct-get medium hi)) 0.785398164)
        (<= (stdlib.math.f64-abs (struct-get medium lo)) 0.000000000000001)
        (<= (stdlib.math.f64-abs (struct-get large64 hi)) 0.785398164)
        (stdlib.math.f64-finite? (struct-get large64 hi))
        (stdlib.math.f64-finite? (struct-get large64 lo))
        (<= (stdlib.math.f64-abs (struct-get large32 hi)) 0.785398164)
        (stdlib.math.f64-finite? (struct-get large32 hi)))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin pi))
        (cast 0x3ca1a62633145c07 : u64))
        unit
        (fail))
      (if (= (stdlib.math.f64-cos pi) -1.0)
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin negative-zero64))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-tan negative-zero64))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-sin negative-zero32))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-tan negative-zero32))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-nan?
          (stdlib.math.f64-sin (stdlib.math.f64-positive-infinity)))
        (stdlib.math.f64-nan?
          (stdlib.math.f64-cos (stdlib.math.f64-negative-infinity)))
        (stdlib.math.f64-nan? (stdlib.math.f64-tan (stdlib.math.f64-quiet-nan)))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-sin (stdlib.math.f32-positive-infinity)))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-cos (stdlib.math.f32-negative-infinity)))
        (stdlib.math.f32-nan? (stdlib.math.f32-tan (stdlib.math.f32-quiet-nan))))
        unit
        (fail)))))

(test
  math-i64-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    (begin
      (if (= (stdlib.math.i64-abs -7) 7)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs 7) 7)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs -9223372036854775808) -9223372036854775808)
        unit
        (fail))
      (if (=
        (stdlib.math.i64-abs-or -9223372036854775808 9223372036854775807)
        9223372036854775807)
        unit
        (fail))
      (if (= (stdlib.math.i64-min -3 9) -3)
        unit
        (fail))
      (if (= (stdlib.math.i64-max -3 9) 9)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 5 0 10) 5)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp -1 0 10) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 11 0 10) 10)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp -1 10 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 11 10 0) 10)
        unit
        (fail))
      (if (stdlib.math.i64-negative? -1)
        unit
        (fail))
      (if (stdlib.math.i64-zero? 0)
        unit
        (fail))
      (if (stdlib.math.i64-positive? 1)
        unit
        (fail))
      (if (not (stdlib.math.i64-positive? 0))
        unit
        (fail)))))

(test
  math-f64-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [abs-neg : f64 -2.5]
    [abs-want : f64 2.5]
    (begin
      (if (= (stdlib.math.f64-abs -2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-abs 0.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-abs 2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.abs abs-neg) abs-want)
        unit
        (fail))
      (if (= (stdlib.math.f64-min -3.5 9.25) -3.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-max -3.5 9.25) 9.25)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 5.5 0.0 10.0) 5.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp -1.0 0.0 10.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 11.0 0.0 10.0) 10.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 11.0 10.0 0.0) 10.0)
        unit
        (fail))
      (if (stdlib.math.f64-negative? -0.5)
        unit
        (fail))
      (if (stdlib.math.f64-zero? 0.0)
        unit
        (fail))
      (if (stdlib.math.f64-positive? 0.5)
        unit
        (fail))
      (if (not (stdlib.math.f64-negative? 0.0))
        unit
        (fail)))))

(test
  math-f32-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [neg : f32 -2.5]
    [zero : f32 0.0]
    [pos : f32 2.5]
    [want : f32 2.5]
    (begin
      (if (= (stdlib.math.f32-abs neg) want)
        unit
        (fail))
      (if (= (stdlib.math.f32-abs zero) zero)
        unit
        (fail))
      (if (= (stdlib.math.f32-abs pos) want)
        unit
        (fail))
      (if (= (stdlib.math.abs neg) want)
        unit
        (fail)))))

(test
  math-float-sqrt
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [one32 : f32 1.0]
    [four32 : f32 4.0]
    [calls : i64 0]
    [once : f64
      (stdlib.math.sqrt
        (begin
          (set! calls (+ calls 1))
          16.0))]
    [sqrt32 : f32 (stdlib.math.sqrt four32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    [nan64 : f64 (stdlib.math.f64-from-bits (cast 0x7ff8000000001234 : u64))]
    [nan32 : f32 (stdlib.math.f32-from-bits (cast 0x7fc01234 : u32))]
    (begin
      (if (and
        (= calls 1)
        (= once 4.0)
        (= sqrt32 (stdlib.math.f32-sqrt four32))
        (= (stdlib.math.f64-sqrt 81.0) 9.0)
        (= (stdlib.math.f32-sqrt one32) one32))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 2.0))
        (cast 0x3ff6a09e667f3bcd : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 3.0))
        (cast 0x3ffbb67ae8584caa : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 10.0))
        (cast 0x40094c583ada5b53 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x3fb999999999999a : u64))))
        (cast 0x3fd43d136248490f : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt (stdlib.math.f64-from-bits (cast 1 : u64))))
        (cast 0x1e60000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x000fffffffffffff : u64))))
        (cast 0x1fffffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x0010000000000000 : u64))))
        (cast 0x2000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x7fefffffffffffff : u64))))
        (cast 0x5fefffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40000000 : u32))))
        (cast 0x3fb504f3 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40400000 : u32))))
        (cast 0x3fddb3d7 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x41200000 : u32))))
        (cast 0x404a62c2 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x3dcccccd : u32))))
        (cast 0x3ea1e89b : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt (stdlib.math.f32-from-bits (cast 1 : u32))))
        (cast 0x1a3504f3 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x007fffff : u32))))
        (cast 0x1fffffff : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x00800000 : u32))))
        (cast 0x20000000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))))
        (cast 0x5f7fffff : u32))
        unit
        (fail))
      (if (and
        (=
          (stdlib.math.f64-to-bits
            (stdlib.math.f64-sqrt (stdlib.math.f64-from-bits (cast 0 : u64))))
          (cast 0 : u64))
        (=
          (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt negative-zero64))
          (cast 0x8000000000000000 : u64))
        (=
          (stdlib.math.f32-to-bits (stdlib.math.f32-sqrt negative-zero32))
          (cast 0x80000000 : u32))
        (stdlib.math.f64-infinite?
          (stdlib.math.f64-sqrt (stdlib.math.f64-positive-infinity)))
        (stdlib.math.f32-infinite?
          (stdlib.math.f32-sqrt (stdlib.math.f32-positive-infinity))))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt -1.0))
        (stdlib.math.f64-nan?
          (stdlib.math.f64-sqrt (stdlib.math.f64-negative-infinity)))
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt nan64))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-sqrt (stdlib.math.f32-negative-infinity)))
        (stdlib.math.f32-nan? (stdlib.math.f32-sqrt nan32)))
        unit
        (fail)))))

(test
  math-f64-ieee-foundation
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [positive-zero : f64 (stdlib.math.f64-from-bits (cast 0 : u64))]
    [negative-zero : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [min-subnormal : f64 (stdlib.math.f64-from-bits (cast 1 : u64))]
    [max-subnormal : f64
      (stdlib.math.f64-from-bits (cast 0x000fffffffffffff : u64))]
    [min-normal : f64
      (stdlib.math.f64-from-bits (cast 0x0010000000000000 : u64))]
    [max-finite : f64
      (stdlib.math.f64-from-bits (cast 0x7fefffffffffffff : u64))]
    [payload-nan : f64
      (stdlib.math.f64-from-bits (cast 0x7ff8000000001234 : u64))]
    (begin
      (if (= (stdlib.math.f64-to-bits positive-zero) (cast 0 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits negative-zero)
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits max-subnormal)
        (cast 0x000fffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits min-normal)
        (cast 0x0010000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits max-finite)
        (cast 0x7fefffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits payload-nan)
        (cast 0x7ff8000000001234 : u64))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-positive-zero? positive-zero)
        (stdlib.math.f64-negative-zero? negative-zero)
        (stdlib.math.f64-signed-zero? negative-zero)
        (stdlib.math.f64-sign-bit? negative-zero)
        (not (stdlib.math.f64-sign-bit? positive-zero)))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-subnormal? min-subnormal)
        (stdlib.math.f64-subnormal? max-subnormal)
        (stdlib.math.f64-normal? min-normal)
        (stdlib.math.f64-finite? max-finite)
        (stdlib.math.f64-infinite? (stdlib.math.f64-positive-infinity))
        (stdlib.math.f64-infinite? (stdlib.math.f64-negative-infinity))
        (stdlib.math.f64-nan? payload-nan))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-copy-sign 3.0 negative-zero))
        (cast 0xc008000000000000 : u64))
        unit
        (fail))
      (if (= (stdlib.math.f64-to-bits (stdlib.math.f64-abs negative-zero)) 0)
        unit
        (fail))
      (if (= (stdlib.math.f64-scalbn 1.5 3) 12.0)
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn min-normal -1))
        (cast 0x0008000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1074))
        (cast 1 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1075))
        (cast 0 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 3.0 -1075))
        (cast 2 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn -1.0 -1075))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (stdlib.math.f64-infinite? (stdlib.math.f64-scalbn max-finite 1))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-scalbn (stdlib.math.f64-positive-infinity) -99))
        (cast 0x7ff0000000000000 : u64))
        unit
        (fail))
      (if (stdlib.math.f64-nan? (stdlib.math.f64-scalbn payload-nan 99))
        unit
        (fail)))))

(test
  math-f32-ieee-foundation
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [positive-zero : f32 (stdlib.math.f32-from-bits (cast 0 : u32))]
    [negative-zero : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    [min-subnormal : f32 (stdlib.math.f32-from-bits (cast 1 : u32))]
    [max-subnormal : f32 (stdlib.math.f32-from-bits (cast 0x007fffff : u32))]
    [min-normal : f32 (stdlib.math.f32-from-bits (cast 0x00800000 : u32))]
    [max-finite : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [payload-nan : f32 (stdlib.math.f32-from-bits (cast 0x7fc01234 : u32))]
    [one : f32 1.0]
    [three : f32 3.0]
    (begin
      (if (= (stdlib.math.f32-to-bits negative-zero) (cast 0x80000000 : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits max-subnormal) (cast 0x007fffff : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits min-normal) (cast 0x00800000 : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits max-finite) (cast 0x7f7fffff : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits payload-nan) (cast 0x7fc01234 : u32))
        unit
        (fail))
      (if (and
        (stdlib.math.f32-positive-zero? positive-zero)
        (stdlib.math.f32-negative-zero? negative-zero)
        (stdlib.math.f32-sign-bit? negative-zero)
        (stdlib.math.f32-subnormal? min-subnormal)
        (stdlib.math.f32-subnormal? max-subnormal)
        (stdlib.math.f32-normal? min-normal)
        (stdlib.math.f32-finite? max-finite)
        (stdlib.math.f32-infinite? (stdlib.math.f32-positive-infinity))
        (stdlib.math.f32-nan? payload-nan))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits (stdlib.math.f32-abs negative-zero)) 0)
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn min-normal -1))
        (cast 0x00400000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -149))
        (cast 1 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -150))
        (cast 0 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn three -150))
        (cast 2 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn negative-zero 1000))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (stdlib.math.f32-infinite? (stdlib.math.f32-scalbn max-finite 1))
        unit
        (fail))
      (if (stdlib.math.f32-nan? (stdlib.math.f32-scalbn payload-nan 99))
        unit
        (fail)))))