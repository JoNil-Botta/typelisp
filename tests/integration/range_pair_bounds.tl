;# The two-sided range rewrite: `(and (>= x lo) (<= x hi))` and its complement
;# `(or (< x lo) (> x hi))` are two compare-and-branch blocks and fold to one
;# unsigned compare, `(x - lo) <=u (hi - lo)`. The subtraction wraps, so the
;# bounds themselves, the values just outside them and i64's own ends are what
;# tell the wrapped test from a signed one. Inputs come from argv so nothing
;# folds, and every form printed here is pinned at opt 0 and opt 2 by the same
;# row in tests/integration/native.manifest.
(import stdlib.io)
(import stdlib.string)

;; Digits, both bound spellings, both forms: `rp-out` and `rp-out-strict` are
;; the complement of `rp-in`.
(define (rp-in [x : i64]) : i64
  (if (and (>= x 48) (<= x 57))
    1
    0))

(define (rp-in-strict [x : i64]) : i64
  (if (and (> x 47) (< x 58))
    1
    0))

(define (rp-out [x : i64]) : i64
  (if (or (< x 48) (> x 57))
    1
    0))

(define (rp-out-strict [x : i64]) : i64
  (if (or (<= x 47) (>= x 58))
    1
    0))

;; A range across zero: `x - lo` is positive for both signs.
(define (rp-centred [x : i64]) : i64
  (if (and (>= x -5) (<= x 5))
    1
    0))

;; Every i64. Its bounds are far outside the literal window the range facts
;; keep, so it stays two compares: a behaviour row at the ends of i64, not a row
;; that exercises the fold.
(define (rp-all [x : i64]) : i64
  (if (and (>= x (- (- 0 9223372036854775807) 1)) (<= x 9223372036854775807))
    1
    0))

;; The single values at i64's ends, the same way: two compares each, and the
;; subtraction the fold would use wraps for everything on one side of them.
(define (rp-top [x : i64]) : i64
  (if (and (>= x 9223372036854775807) (<= x 9223372036854775807))
    1
    0))

(define (rp-bottom [x : i64]) : i64
  (if (and
    (>= x (- (- 0 9223372036854775807) 1))
    (<= x (- (- 0 9223372036854775807) 1)))
    1
    0))

(define (main) : i64
  (let
    [count : i64 (io.arg-count)]
    [i : i64 1]
    (while (< i count)
      (let
        [n : i64 (string.>int (io.arg i))]
        (io.println
          "{} {} {} {} {} {} {} {} {}"
          n
          (rp-in n)
          (rp-in-strict n)
          (rp-out n)
          (rp-out-strict n)
          (rp-centred n)
          (rp-all n)
          (rp-top n)
          (rp-bottom n))
        (set! i (+ i 1))))
    42))