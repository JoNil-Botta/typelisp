;# Deterministic hash helpers for stdlib collections (#815).
;#
;# This module provides stable, non-cryptographic hash building blocks for
;# future maps, sets, intern tables, and compiler data structures. Hash values
;# are normalized nonnegative `i64` values in `0 <= hash < hash-modulus`.
;#
;# A hash is only a bucket hint. Key users must still compare candidate keys
;# with the matching equality predicate because different keys can collide.
;# These helpers do not allocate; they only inspect scalar values and String
;# bytes/chars already owned by the caller.
;#
;# Usage: `(import "stdlib/hash.tl")`
;#
;# ```typelisp
;# (import "stdlib/hash.tl")
;# (define (main) : i64
;#   (let [key : String "symbol"]
;#     (hash-combine (hash-string (& key)) (hash-i64 7))))
;# ```
;: Return the fixed hash modulus.
(define (hash-modulus) : i64
  2147483647)

;: Return the fixed multiplier used by `hash-combine` and `hash-string`.
(define (hash-multiplier) : i64
  131)

;: Normalize any integer into the public hash range.
(define (hash-normalize [value : i64]) : i64
  (let
    [m : i64 2147483647]
    [raw : i64 (% value 2147483647)]
    (if (< raw 0)
      (+ raw m)
      raw)))

;: Combine an accumulated hash value with one component hash.
;:
;: The result is deterministic and non-cryptographic. The `+ 1` delimiter keeps
;: `hash-combine 0 0` distinct from an untouched empty accumulator.
(define (hash-combine [seed : i64] [component : i64]) : i64
  (hash-normalize
    (+ (+ (* (hash-normalize seed) 131) (hash-normalize component)) 1)))

;: Combine already-normalized hash parts without re-normalizing inputs.
(define (hash-combine-normalized [seed : i64] [component : i64]) : i64
  (hash-normalize (+ (+ (* seed 131) component) 1)))

;: Hash an `i64` key value.
(define (hash-i64 [value : i64]) : i64
  (hash-normalize value))

;: Return true when two `i64` keys are equal.
(define (hash-key-i64-eq? [a : i64] [b : i64]) : bool
  (= a b))

;: Hash a `bool` key value.
(define (hash-bool [value : bool]) : i64
  (if value
    1
    0))

;: Return true when two `bool` keys are equal.
(define (hash-key-bool-eq? [a : bool] [b : bool]) : bool
  (= a b))

;: Hash a `char` key value by scalar code.
(define (hash-char [value : char]) : i64
  (hash-normalize (cast value : i64)))

;: Return true when two `char` keys have the same scalar code.
(define (hash-key-char-eq? [a : char] [b : char]) : bool
  (= (cast a : i64) (cast b : i64)))

;: Hash borrowed text by walking its current byte/char sequence.
;:
;: Hash values are bucket hints only; key users must still compare candidate keys
;: with the matching equality predicate because different keys can collide.
(define (hash-string [key : (& key str)]) : i64
  (let
    [n : i64 (string-length key)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            hash
            (%
              (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)
              2147483647))
          (set! i (+ i 1))))
      hash)))

;: Return true when two borrowed string keys are equal.
(define (hash-key-string-eq? [a : (& a str)] [b : (& b str)]) : bool
  (string-eq a b))