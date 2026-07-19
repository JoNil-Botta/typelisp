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