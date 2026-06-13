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
(import "string.tl")

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
      (while (>= (- n i) 4)
        (let
          [h1 : i64 (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)]
          [h2 : i64 (+ (+ (* h1 131) (cast (string-ref key (+ i 1)) : i64)) 1)]
          [h3 : i64 (+ (+ (* h2 131) (cast (string-ref key (+ i 2)) : i64)) 1)]
          [h4 : i64 (+ (+ (* h3 131) (cast (string-ref key (+ i 3)) : i64)) 1)]
          [reduced : i64 (+ (bit-and h4 0x7fffffff) (shr h4 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 4)))))
      (while (< i n)
        (let
          [next : i64 (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)]
          [reduced : i64 (+ (bit-and next 0x7fffffff) (shr next 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 1)))))
      hash)))

;: Return true when two borrowed string keys are equal.
(define (hash-key-string-eq? [a : (& a str)] [b : (& b str)]) : bool
  (string-eq-borrowed a b))

(test
  hash-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [empty : String ""]
    [a : String "a"]
    [ab : String "ab"]
    [abc : String "abc"]
    [abcd : String "abcd"]
    [abcdefgh : String "abcdefgh"]
    [ba : String "ba"]
    [a-newline-b : String "a\nb"]
    [bc : String "bc"]
    [joined : String (string-append a bc)]
    [same : String "same"]
    [same-copy : String (string-append "sa" "me")]
    [different : String "different"]
    [edge : String "edge\ncase"]
    [range-min : i64 (hash-i64 -9223372036854775808)]
    [range-max : i64 (hash-i64 9223372036854775807)]
    [range-combine : i64 (hash-combine -1 -1)]
    [range-empty : i64 (hash-string (& empty))]
    [range-edge : i64 (hash-string (& edge))]
    (begin
      (if (= (hash-modulus) 2147483647)
        unit
        (fail))
      (if (= (hash-multiplier) 131)
        unit
        (fail))
      (if (= (hash-normalize 2147483647) 0)
        unit
        (fail))
      (if (= (hash-normalize -1) 2147483646)
        unit
        (fail))
      (if (= (hash-i64 42) 42)
        unit
        (fail))
      (if (= (hash-i64 -42) 2147483605)
        unit
        (fail))
      (if (= (hash-bool false) 0)
        unit
        (fail))
      (if (= (hash-bool true) 1)
        unit
        (fail))
      (if (= (hash-char #A') 65)
        unit
        (fail))
      (if (= (hash-char #\newline') 10)
        unit
        (fail))
      (if (= (hash-combine 0 0) 1)
        unit
        (fail))
      (if (= (hash-combine 42 7) 5510)
        unit
        (fail))
      (if (= (hash-string (& empty)) 0)
        unit
        (fail))
      (if (= (hash-string (& a)) 98)
        unit
        (fail))
      (if (= (hash-string (& ab)) 12937)
        unit
        (fail))
      (if (= (hash-string (& abc)) 1694847)
        unit
        (fail))
      (if (= (hash-string (& abcd)) 222025058)
        unit
        (fail))
      (if (= (hash-string (& abcdefgh)) 1379066653)
        unit
        (fail))
      (if (= (hash-string (& ba)) 13067)
        unit
        (fail))
      (if (= (hash-string (& a-newline-b)) 1683318)
        unit
        (fail))
      (if (= (hash-i64 42) (hash-i64 (+ 40 2)))
        unit
        (fail))
      (if (= (hash-bool true) (hash-bool (not false)))
        unit
        (fail))
      (if (= (hash-char #A') (hash-char (string-ref "A" 0)))
        unit
        (fail))
      (if (= (hash-string (& abc)) (hash-string (& joined)))
        unit
        (fail))
      (if (hash-key-i64-eq? 5 5)
        unit
        (fail))
      (if (not (hash-key-i64-eq? 5 6))
        unit
        (fail))
      (if (hash-key-bool-eq? true true)
        unit
        (fail))
      (if (not (hash-key-bool-eq? true false))
        unit
        (fail))
      (if (hash-key-char-eq? #x' #x')
        unit
        (fail))
      (if (not (hash-key-char-eq? #x' #y'))
        unit
        (fail))
      (if (hash-key-string-eq? (& same) (& same-copy))
        unit
        (fail))
      (if (not (hash-key-string-eq? (& same) (& different)))
        unit
        (fail))
      (if (= (hash-i64 0) (hash-i64 2147483647))
        unit
        (fail))
      (if (not (hash-key-i64-eq? 0 2147483647))
        unit
        (fail))
      (if (= (hash-combine 0 131) (hash-combine 1 0))
        unit
        (fail))
      (if (not (hash-key-i64-eq? 0 1))
        unit
        (fail))
      (if (and (>= range-min 0) (< range-min (hash-modulus)))
        unit
        (fail))
      (if (and (>= range-max 0) (< range-max (hash-modulus)))
        unit
        (fail))
      (if (and (>= range-combine 0) (< range-combine (hash-modulus)))
        unit
        (fail))
      (if (and (>= range-empty 0) (< range-empty (hash-modulus)))
        unit
        (fail))
      (if (and (>= range-edge 0) (< range-edge (hash-modulus)))
        unit
        (fail)))))