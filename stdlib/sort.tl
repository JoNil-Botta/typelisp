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
;# Usage: `(import stdlib.sort)`
;#
;# ```typelisp
;# (import stdlib.vector)
;# (import stdlib.sort)
;#
;# (define (main) : i64
;#   (let
;#     [v : vector.I64Vec
;#       (vector.i64-vec-push
;#         (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-new) 3) 1)
;#         2)]
;#     [sorted : vector.I64Vec (sort.i64-vec-sort! v)]
;#     (+ (vector.i64-vec-get sorted 0 0) (vector.i64-vec-get sorted 2 0))))
;# ```
(module stdlib.sort)

(import stdlib.vector as vector_mod)

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
          [lc : i64 (stdlib.sort.sort-char-code-at left idx)]
          [rc : i64 (stdlib.sort.sort-char-code-at right idx)]
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
  (stdlib.sort.sort-string-less-borrowed? (& left) (& right)))

;: Stable in-place ascending insertion sort for an `I64Vec`. Mutates the
;: vector's existing backing array and returns the same threaded vector value.
(define (i64-vec-sort! [v : vector_mod.I64Vec]) : vector_mod.I64Vec
  (let
    [slots : (Array i64) (vector_mod.i64-vec-slots v)]
    [n : i64 (vector_mod.i64-vec-len v)]
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
(define (string-vec-sort! [v : vector_mod.StringVec]) : vector_mod.StringVec
  (let
    [slots : (Array String) (vector_mod.string-vec-slots v)]
    [n : i64 (vector_mod.string-vec-len v)]
    [i : i64 1]
    (begin
      (while (< i n)
        (let
          [value : String (array-ref slots i)]
          [j : i64 i]
          (begin
            (while (and
              (> j 0)
              (stdlib.sort.sort-string-less? value (array-ref slots (- j 1))))
              (begin
                (array-set! slots j (array-ref slots (- j 1)))
                (set! j (- j 1))))
            (array-set! slots j value)
            (set! i (+ i 1)))))
      v)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value sort-char-code-at)
  (value sort-string-less-borrowed?)
  (value sort-string-less?)
  (value i64-vec-sort!)
  (value string-vec-sort!))