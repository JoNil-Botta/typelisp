;# Pure scalar math helpers.
;#
;# This module provides small, zero-dependency helpers for scalar integer and
;# float values. The v1 surface is deliberately limited to operations expressible
;# with TypeLisp's built-in arithmetic and comparisons: absolute value, min,
;# max, clamp, and sign predicates for `i64` and `f64`.
;#
;# Transcendental and libm-style functions such as `sqrt`, `sin`, `cos`, `tan`,
;# `log`, and `pow` are intentionally not part of this module yet. They need a
;# later freestanding soft-math implementation or an explicit platform-extern
;# policy so Linux and Windows stdlib behavior does not accidentally diverge.
;#
;# All helpers are non-allocating and import no other stdlib modules.
;#
;# Usage: `(import stdlib.math)`
;#
;# ```typelisp
;# (import stdlib.math)
;# (define (main) : i64
;#   (math.math-i64-clamp (math.math-i64-abs -50) 0 42))
;# ```
(module stdlib.math)

;: Return the absolute value of an `i64`.
;:
;: The positive magnitude of the most-negative `i64` is not representable, so
;: that value is returned unchanged. Use `math-i64-abs-or` to choose a fallback.
(define (math-i64-abs [value : i64]) : i64
  (stdlib.math.math-i64-abs-or value value))

;: Return the absolute value of an `i64`, or `fallback` for the most-negative
;: `i64` whose positive magnitude is not representable.
(define (math-i64-abs-or [value : i64] [fallback : i64]) : i64
  (if (= value -9223372036854775808)
    fallback
    (if (< value 0)
      (- 0 value)
      value)))

;: Return the smaller `i64` value.
(define (math-i64-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

;: Return the larger `i64` value.
(define (math-i64-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `i64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (math-i64-clamp [value : i64] [a : i64] [b : i64]) : i64
  (let
    [lo : i64 (stdlib.math.math-i64-min a b)]
    [hi : i64 (stdlib.math.math-i64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (math-i64-negative? [value : i64]) : bool
  (< value 0))

;: True when `value` is equal to zero.
(define (math-i64-zero? [value : i64]) : bool
  (= value 0))

;: True when `value` is greater than zero.
(define (math-i64-positive? [value : i64]) : bool
  (> value 0))

;: Return the absolute value of an `f64`.
(define (math-f64-abs [value : f64]) : f64
  (if (< value 0.0)
    (- 0.0 value)
    value))

;: Return the smaller `f64` value according to TypeLisp scalar comparison.
(define (math-f64-min [a : f64] [b : f64]) : f64
  (if (< a b)
    a
    b))

;: Return the larger `f64` value according to TypeLisp scalar comparison.
(define (math-f64-max [a : f64] [b : f64]) : f64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `f64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (math-f64-clamp [value : f64] [a : f64] [b : f64]) : f64
  (let
    [lo : f64 (stdlib.math.math-f64-min a b)]
    [hi : f64 (stdlib.math.math-f64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (math-f64-negative? [value : f64]) : bool
  (< value 0.0))

;: True when `value` is equal to zero.
(define (math-f64-zero? [value : f64]) : bool
  (= value 0.0))

;: True when `value` is greater than zero.
(define (math-f64-positive? [value : f64]) : bool
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
      (if (= (stdlib.math.math-i64-abs -7) 7)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-abs 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-abs 7) 7)
        unit
        (fail))
      (if (=
        (stdlib.math.math-i64-abs -9223372036854775808)
        -9223372036854775808)
        unit
        (fail))
      (if (=
        (stdlib.math.math-i64-abs-or -9223372036854775808 9223372036854775807)
        9223372036854775807)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-min -3 9) -3)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-max -3 9) 9)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-clamp 5 0 10) 5)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-clamp -1 0 10) 0)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-clamp 11 0 10) 10)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-clamp -1 10 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.math-i64-clamp 11 10 0) 10)
        unit
        (fail))
      (if (stdlib.math.math-i64-negative? -1)
        unit
        (fail))
      (if (stdlib.math.math-i64-zero? 0)
        unit
        (fail))
      (if (stdlib.math.math-i64-positive? 1)
        unit
        (fail))
      (if (not (stdlib.math.math-i64-positive? 0))
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
    (begin
      (if (= (stdlib.math.math-f64-abs -2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-abs 0.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-abs 2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-min -3.5 9.25) -3.5)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-max -3.5 9.25) 9.25)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-clamp 5.5 0.0 10.0) 5.5)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-clamp -1.0 0.0 10.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-clamp 11.0 0.0 10.0) 10.0)
        unit
        (fail))
      (if (= (stdlib.math.math-f64-clamp 11.0 10.0 0.0) 10.0)
        unit
        (fail))
      (if (stdlib.math.math-f64-negative? -0.5)
        unit
        (fail))
      (if (stdlib.math.math-f64-zero? 0.0)
        unit
        (fail))
      (if (stdlib.math.math-f64-positive? 0.5)
        unit
        (fail))
      (if (not (stdlib.math.math-f64-negative? 0.0))
        unit
        (fail)))))

(export
  (value math-i64-abs)
  (value math-i64-abs-or)
  (value math-i64-min)
  (value math-i64-max)
  (value math-i64-clamp)
  (value math-i64-negative?)
  (value math-i64-zero?)
  (value math-i64-positive?)
  (value math-f64-abs)
  (value math-f64-min)
  (value math-f64-max)
  (value math-f64-clamp)
  (value math-f64-negative?)
  (value math-f64-zero?)
  (value math-f64-positive?))