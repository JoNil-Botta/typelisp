;# Stable deterministic sort helpers for concrete stdlib vectors (#2678).
;#
;# This module intentionally follows the generated concrete collection model:
;# it exposes monomorphic helpers for the vector families that exist today
;# instead of introducing traits, generic comparators, or compiler-level
;# constraints.
;#
;# `i64-vec-sort!` orders `I64Vec` values ascending by numeric value.
;# `string-vec-sort!` orders `StringVec` values lexicographically by character
;# code. Both use stable insertion sort and mutate only the live prefix
;# `[0, len)` of the existing backing array.
;#
;# Usage: `(import "stdlib/sort.tl")`
;#
;# ```typelisp
;# (import "stdlib/vector.tl")
;# (import "stdlib/sort.tl")
;#
;# (define (main) : i64
;#   (let
;#     [v : I64Vec
;#       (i64-vec-push
;#         (i64-vec-push (i64-vec-push (i64-vec-new) 3) 1)
;#         2)]
;#     [sorted : I64Vec (i64-vec-sort! v)]
;#     (+ (i64-vec-get sorted 0 0) (i64-vec-get sorted 2 0))))
;# ```
(import "vector.tl")

;: Return the character code at `idx` in borrowed text.
(define (sort-char-code-at [text : (& text str)] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

;: Return true when `left` is lexicographically before `right` by character
;: code. Prefixes sort before longer strings with the same prefix.
(define (sort-string-less-borrowed?
  [left : (& left str)]
  [right : (& right str)]) : bool
  (let
    [left-len : i64 (string-length left)]
    [right-len : i64 (string-length right)]
    [limit : i64
      (if (< left-len right-len)
        left-len
        right-len)]
    [idx : i64 0]
    [done : bool false]
    [less : bool false]
    (begin
      (while (and (not done) (< idx limit))
        (let
          [lc : i64 (sort-char-code-at left idx)]
          [rc : i64 (sort-char-code-at right idx)]
          (if (= lc rc)
            (set! idx (+ idx 1))
            (begin
              (set! less (< lc rc))
              (set! done true)))))
      (if done
        less
        (< left-len right-len)))))

;: Owned-string wrapper for `sort-string-less-borrowed?`.
(define (sort-string-less? [left : String] [right : String]) : bool
  (sort-string-less-borrowed? (& left) (& right)))

;: Stable in-place ascending insertion sort for an `I64Vec`. Mutates the
;: vector's existing backing array and returns the same threaded vector value.
(define (i64-vec-sort! [v : I64Vec]) : I64Vec
  (let
    [slots : (Array i64) (i64-vec-slots v)]
    [n : i64 (i64-vec-len v)]
    [i : i64 1]
    (begin
      (while (< i n)
        (let
          [value : i64 (array-ref slots i)]
          [j : i64 i]
          (begin
            (while (and (> j 0) (< value (array-ref slots (- j 1))))
              (begin
                (array-set! slots j (array-ref slots (- j 1)))
                (set! j (- j 1))))
            (array-set! slots j value)
            (set! i (+ i 1)))))
      v)))

;: Stable in-place ascending insertion sort for a `StringVec`, using
;: lexicographic character-code ordering. Mutates the vector's existing backing
;: array and returns the same threaded vector value.
(define (string-vec-sort! [v : StringVec]) : StringVec
  (let
    [slots : (Array String) (string-vec-slots v)]
    [n : i64 (string-vec-len v)]
    [i : i64 1]
    (begin
      (while (< i n)
        (let
          [value : String (array-ref slots i)]
          [j : i64 i]
          (begin
            (while (and
              (> j 0)
              (sort-string-less? value (array-ref slots (- j 1))))
              (begin
                (array-set! slots j (array-ref slots (- j 1)))
                (set! j (- j 1))))
            (array-set! slots j value)
            (set! i (+ i 1)))))
      v)))

;; Inline coverage migrated from stdlib/tests/sort_api.tl (#3082).
(cfg test (import "test.tl"))

(cfg
  test
  (define (sort-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (sort-test-make-i64-vec1 [a : i64]) : I64Vec
    (i64-vec-push (i64-vec-new) a)))

(cfg
  test
  (define (sort-test-make-i64-vec3 [a : i64] [b : i64] [c : i64]) : I64Vec
    (i64-vec-push (i64-vec-push (i64-vec-push (i64-vec-new) a) b) c)))

(cfg
  test
  (define (sort-test-make-i64-vec5
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]) : I64Vec
    (i64-vec-push
      (i64-vec-push
        (i64-vec-push (i64-vec-push (i64-vec-push (i64-vec-new) a) b) c)
        d)
      e)))

(cfg
  test
  (define (sort-test-assert-i64-vec1 [v : I64Vec] [a : i64]) : unit
    (begin
      (assert-i64-eq (i64-vec-len v) 1 "i64 vec1 len")
      (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec1 0"))))

(cfg
  test
  (define (sort-test-assert-i64-vec3 [v : I64Vec] [a : i64] [b : i64] [c : i64]) : unit
    (begin
      (assert-i64-eq (i64-vec-len v) 3 "i64 vec3 len")
      (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec3 0")
      (assert-i64-eq (i64-vec-get v 1 9999) b "i64 vec3 1")
      (assert-i64-eq (i64-vec-get v 2 9999) c "i64 vec3 2"))))

(cfg
  test
  (define (sort-test-assert-i64-vec5
    [v : I64Vec]
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]) : unit
    (begin
      (assert-i64-eq (i64-vec-len v) 5 "i64 vec5 len")
      (assert-i64-eq (i64-vec-get v 0 9999) a "i64 vec5 0")
      (assert-i64-eq (i64-vec-get v 1 9999) b "i64 vec5 1")
      (assert-i64-eq (i64-vec-get v 2 9999) c "i64 vec5 2")
      (assert-i64-eq (i64-vec-get v 3 9999) d "i64 vec5 3")
      (assert-i64-eq (i64-vec-get v 4 9999) e "i64 vec5 4"))))

(cfg
  test
  (define (sort-test-make-string-vec1 [a : String]) : StringVec
    (string-vec-push (string-vec-new) a)))

(cfg
  test
  (define (sort-test-make-string-vec4
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : StringVec
    (string-vec-push
      (string-vec-push
        (string-vec-push (string-vec-push (string-vec-new) a) b)
        c)
      d)))

(cfg
  test
  (define (sort-test-assert-string-vec1 [v : StringVec] [a : String]) : unit
    (begin
      (assert-i64-eq (string-vec-len v) 1 "string vec1 len")
      (sort-test-assert-owned-string-eq
        (string-vec-get v 0 "missing")
        a
        "string vec1 0"))))

(cfg
  test
  (define (sort-test-assert-string-vec4
    [v : StringVec]
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : unit
    (begin
      (assert-i64-eq (string-vec-len v) 4 "string vec4 len")
      (sort-test-assert-owned-string-eq
        (string-vec-get v 0 "missing")
        a
        "string vec4 0")
      (sort-test-assert-owned-string-eq
        (string-vec-get v 1 "missing")
        b
        "string vec4 1")
      (sort-test-assert-owned-string-eq
        (string-vec-get v 2 "missing")
        c
        "string vec4 2")
      (sort-test-assert-owned-string-eq
        (string-vec-get v 3 "missing")
        d
        "string vec4 3"))))

(cfg
  test
  (define (sort-test-assert-i64-sort-cases) : unit
    (begin
      (let
        [empty : I64Vec (i64-vec-sort! (i64-vec-new))]
        (begin
          (assert-i64-eq (i64-vec-len empty) 0 "empty i64 sort len")
          (assert-true
            (>= (i64-vec-capacity empty) 1)
            "empty i64 sort growable")))
      (sort-test-assert-i64-vec1 (i64-vec-sort! (sort-test-make-i64-vec1 7)) 7)
      (sort-test-assert-i64-vec3
        (i64-vec-sort! (sort-test-make-i64-vec3 1 2 3))
        1
        2
        3)
      (sort-test-assert-i64-vec5
        (i64-vec-sort! (sort-test-make-i64-vec5 5 4 3 2 1))
        1
        2
        3
        4
        5)
      (sort-test-assert-i64-vec5
        (i64-vec-sort! (sort-test-make-i64-vec5 3 1 3 2 1))
        1
        1
        2
        3
        3)
      (sort-test-assert-i64-vec5
        (i64-vec-sort! (sort-test-make-i64-vec5 0 -10 5 -10 2))
        -10
        -10
        0
        2
        5))))

(cfg
  test
  (define (sort-test-assert-string-less-cases) : unit
    (begin
      (assert-true (sort-string-less? "" "a") "empty string sorts first")
      (assert-true (sort-string-less? "a" "aa") "prefix sorts first")
      (assert-true (sort-string-less? "alpha" "beta") "alpha before beta")
      (assert-false (sort-string-less? "beta" "alpha") "beta after alpha")
      (assert-false (sort-string-less? "same" "same") "equal is not less"))))

(cfg
  test
  (define (sort-test-assert-string-sort-cases) : unit
    (begin
      (let
        [empty : StringVec (string-vec-sort! (string-vec-new))]
        (begin
          (assert-i64-eq (string-vec-len empty) 0 "empty string sort len")
          (assert-true
            (>= (string-vec-capacity empty) 1)
            "empty string sort growable")))
      (sort-test-assert-string-vec1
        (string-vec-sort! (sort-test-make-string-vec1 "solo"))
        "solo")
      (sort-test-assert-string-vec4
        (string-vec-sort!
          (sort-test-make-string-vec4 "alpha" "bravo" "charlie" "delta"))
        "alpha"
        "bravo"
        "charlie"
        "delta")
      (sort-test-assert-string-vec4
        (string-vec-sort!
          (sort-test-make-string-vec4 "delta" "alpha" "charlie" "bravo"))
        "alpha"
        "bravo"
        "charlie"
        "delta")
      (sort-test-assert-string-vec4
        (string-vec-sort! (sort-test-make-string-vec4 "b" "aa" "a" ""))
        ""
        "a"
        "aa"
        "b")
      (sort-test-assert-string-vec4
        (string-vec-sort!
          (sort-test-make-string-vec4 "beta" "alpha" "beta" "alpha"))
        "alpha"
        "alpha"
        "beta"
        "beta"))))

(cfg
  test
  (define (sort-test-main) : i64
    (begin
      (sort-test-assert-i64-sort-cases)
      (sort-test-assert-string-less-cases)
      (sort-test-assert-string-sort-cases)
      42)))

(cfg
  test
  (test sort-api (assert-i64-eq (sort-test-main) 42 "sort-api fixture result")))