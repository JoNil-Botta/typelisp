;# Stable deterministic sort helpers for generated stdlib vectors (#2678/#3218).
;#
;# This module follows the generated concrete collection model. `(sort-vec T)`
;# emits a module that sorts the matching `(vector T)` module's `Vec` in place.
;# Scalar element types with a built-in `<` get `sort!`; non-scalar element
;# types get `sort!` with an explicit caller-supplied `less?` comparator.
;#
;# Generated sorts use stable insertion sort and mutate only the live prefix
;# `[0, len)` of the existing backing array.
;#
;# Usage: `(import stdlib.sort)`
;#
;# ```typelisp
;# (import stdlib.vector)
;# (import stdlib.sort)
;#
;# (import (stdlib.vector.vector i64) as ivec)
;# (import (stdlib.sort.sort-vec i64) as isort)
;#
;# (define (main) : i64
;#   (let
;#     [v : ivec.Vec (ivec.new)]
;#     (begin
;#       (ivec.push (&mut v) 3)
;#       (ivec.push (&mut v) 1)
;#       (ivec.push (&mut v) 2)
;#       (isort.sort! (&mut v))
;#       (+ (ivec.get (& v) 0 0) (ivec.get (& v) 2 0)))))
;# ```
(module stdlib.sort)

;: Return the character code at `idx` in borrowed text.
(define (sort-char-code-at [text : (& text str)] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

;: Return true when `left` is lexicographically before `right` by character
;: code. Prefixes sort before longer strings with the same prefix.
(define (string-less-borrowed? [left : (& left str)] [right : (& right str)]) : bool
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

;: Owned-string wrapper for `string-less-borrowed?`.
(define (string-less? [left : String] [right : String]) : bool
  (stdlib.sort.string-less-borrowed? (& left) (& right)))

;: Emit a stable in-place ascending insertion sort module for `(vector T)`.
;:
;: Scalar element types expose `(sort! (&mut v))` and compare with the built-in
;: `<`. Non-scalar element types expose `(sort! (&mut v) less?)`, where `less?`
;: has type `(-> T T bool)` and returns true when the first value should sort
;: before the second.
(defmacro (sort-vec [T : type]) : Module
  (let
    [type-key-name : String (type-key T)]
    [module-name : Expr
      (expr-var (string-append "stdlib.vector.generated." type-key-name))]
    [kind : String (type-kind T)]
    [scalar? : bool
      (match kind
        ["i64" true]
        ["i32" true]
        ["i16" true]
        ["i8" true]
        ["u64" true]
        ["u32" true]
        ["u16" true]
        ["u8" true]
        ["f64" true]
        ["f32" true]
        [_ false])]
    (if scalar?
      `(begin
        (module ,module-name)
        (define (sort! [v : (&mut v Vec)]) : unit
          (let
            [n : i64 (len-mut v)]
            [slots : (&mut v (Array ,T)) (slots-mut v)]
            [i : i64 1]
            (while (< i n)
              (let
                [value : ,T (array-ref slots i)]
                [j : i64 i]
                (begin
                  (while (if (> j 0)
                    (< value (array-ref slots (- j 1)))
                    false)
                    (begin
                      (array-set! slots j (array-ref slots (- j 1)))
                      (set! j (- j 1))))
                  (array-set! slots j value)
                  (set! i (+ i 1)))))))
        (export (value sort!)))
      `(begin
        (module ,module-name)
        (define (sort! [v : (&mut v Vec)] [less? : (-> ,T ,T bool)]) : unit
          (let
            [n : i64 (len-mut v)]
            [slots : (&mut v (Array ,T)) (slots-mut v)]
            [i : i64 1]
            (while (< i n)
              (let
                [value : ,T (array-ref slots i)]
                [j : i64 i]
                (begin
                  (while (if (> j 0)
                    (less? (clone value) (clone (array-ref slots (- j 1))))
                    false)
                    (begin
                      (array-set! slots j (clone (array-ref slots (- j 1))))
                      (set! j (- j 1))))
                  (array-set! slots j value)
                  (set! i (+ i 1)))))))
        (export (value sort!))))))

(export
  (macro sort-vec)
  (value sort-char-code-at)
  (value string-less-borrowed?)
  (value string-less?))

;; Inline coverage migrated from the old flat vector sort helpers (#3082).
(cfg test (import stdlib.vector))
(cfg test (import stdlib.test))
(cfg test (import (stdlib.vector.vector i64) as i64v))
(cfg test (import (stdlib.sort.sort-vec i64) as i64sort))
(cfg test (import (stdlib.sort.sort-vec i64) as i64sort_again))
(cfg test (import (stdlib.vector.vector String) as strv))
(cfg test (import (stdlib.sort.sort-vec String) as strsort))

(cfg
  test
  (defstruct SortPair
    (key i64)
    (seq i64)))

(cfg test (export (type SortPair) (constructor SortPair)))

(cfg test (import (stdlib.vector.vector SortPair) as pairv))
(cfg test (import (stdlib.sort.sort-vec SortPair) as pairsort))

(cfg
  test
  (define (sort-test-pair-less? [left : SortPair] [right : SortPair]) : bool
    (< (struct-get left key) (struct-get right key))))

(cfg
  test
  (define (sort-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (test.assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (sort-test-make-i64-vec1 [a : i64]) : i64v.Vec
    (let
      [v : i64v.Vec (i64v.new)]
      (begin
        (i64v.push (&mut v) a)
        v))))

(cfg
  test
  (define (sort-test-make-i64-vec3 [a : i64] [b : i64] [c : i64]) : i64v.Vec
    (let
      [v : i64v.Vec (i64v.new)]
      (begin
        (i64v.push (&mut v) a)
        (i64v.push (&mut v) b)
        (i64v.push (&mut v) c)
        v))))

(cfg
  test
  (define (sort-test-make-i64-vec5
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]) : i64v.Vec
    (let
      [v : i64v.Vec (i64v.new)]
      (begin
        (i64v.push (&mut v) a)
        (i64v.push (&mut v) b)
        (i64v.push (&mut v) c)
        (i64v.push (&mut v) d)
        (i64v.push (&mut v) e)
        v))))

(cfg
  test
  (define (sort-test-assert-i64-vec1 [v : i64v.Vec] [a : i64]) : unit
    (begin
      (test.assert-i64-eq (i64v.len (& v)) 1 "i64 vec1 len")
      (test.assert-i64-eq (i64v.get (& v) 0 9999) a "i64 vec1 0"))))

(cfg
  test
  (define (sort-test-assert-i64-vec3
    [v : i64v.Vec]
    [a : i64]
    [b : i64]
    [c : i64]) : unit
    (begin
      (test.assert-i64-eq (i64v.len (& v)) 3 "i64 vec3 len")
      (test.assert-i64-eq (i64v.get (& v) 0 9999) a "i64 vec3 0")
      (test.assert-i64-eq (i64v.get (& v) 1 9999) b "i64 vec3 1")
      (test.assert-i64-eq (i64v.get (& v) 2 9999) c "i64 vec3 2"))))

(cfg
  test
  (define (sort-test-assert-i64-vec5
    [v : i64v.Vec]
    [a : i64]
    [b : i64]
    [c : i64]
    [d : i64]
    [e : i64]) : unit
    (begin
      (test.assert-i64-eq (i64v.len (& v)) 5 "i64 vec5 len")
      (test.assert-i64-eq (i64v.get (& v) 0 9999) a "i64 vec5 0")
      (test.assert-i64-eq (i64v.get (& v) 1 9999) b "i64 vec5 1")
      (test.assert-i64-eq (i64v.get (& v) 2 9999) c "i64 vec5 2")
      (test.assert-i64-eq (i64v.get (& v) 3 9999) d "i64 vec5 3")
      (test.assert-i64-eq (i64v.get (& v) 4 9999) e "i64 vec5 4"))))

(cfg
  test
  (define (sort-test-make-string-vec1 [a : String]) : strv.Vec
    (let
      [v : strv.Vec (strv.new)]
      (begin
        (strv.push (&mut v) a)
        v))))

(cfg
  test
  (define (sort-test-make-string-vec4
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : strv.Vec
    (let
      [v : strv.Vec (strv.new)]
      (begin
        (strv.push (&mut v) a)
        (strv.push (&mut v) b)
        (strv.push (&mut v) c)
        (strv.push (&mut v) d)
        v))))

(cfg
  test
  (define (sort-test-assert-string-vec1 [v : strv.Vec] [a : String]) : unit
    (begin
      (test.assert-i64-eq (strv.len (& v)) 1 "string vec1 len")
      (sort-test-assert-owned-string-eq
        (strv.get (& v) 0 "missing")
        a
        "string vec1 0"))))

(cfg
  test
  (define (sort-test-assert-string-vec4
    [v : strv.Vec]
    [a : String]
    [b : String]
    [c : String]
    [d : String]) : unit
    (begin
      (test.assert-i64-eq (strv.len (& v)) 4 "string vec4 len")
      (sort-test-assert-owned-string-eq
        (strv.get (& v) 0 "missing")
        a
        "string vec4 0")
      (sort-test-assert-owned-string-eq
        (strv.get (& v) 1 "missing")
        b
        "string vec4 1")
      (sort-test-assert-owned-string-eq
        (strv.get (& v) 2 "missing")
        c
        "string vec4 2")
      (sort-test-assert-owned-string-eq
        (strv.get (& v) 3 "missing")
        d
        "string vec4 3"))))

(cfg
  test
  (define (sort-test-assert-i64-sort-cases) : unit
    (begin
      (let
        [empty : i64v.Vec (i64v.new)]
        (begin
          (i64sort.sort! (&mut empty))
          (test.assert-i64-eq (i64v.len (& empty)) 0 "empty i64 sort len")
          (test.assert-true
            (>= (i64v.capacity (& empty)) 1)
            "empty i64 sort growable")))
      (let
        [single : i64v.Vec (sort-test-make-i64-vec1 7)]
        (begin
          (i64sort.sort! (&mut single))
          (sort-test-assert-i64-vec1 single 7)))
      (let
        [sorted : i64v.Vec (sort-test-make-i64-vec3 1 2 3)]
        (begin
          (i64sort.sort! (&mut sorted))
          (sort-test-assert-i64-vec3 sorted 1 2 3)))
      (let
        [reverse : i64v.Vec (sort-test-make-i64-vec5 5 4 3 2 1)]
        (begin
          (i64sort.sort! (&mut reverse))
          (sort-test-assert-i64-vec5 reverse 1 2 3 4 5)))
      (let
        [dupes : i64v.Vec (sort-test-make-i64-vec5 3 1 3 2 1)]
        (begin
          (i64sort_again.sort! (&mut dupes))
          (sort-test-assert-i64-vec5 dupes 1 1 2 3 3)))
      (let
        [negative : i64v.Vec (sort-test-make-i64-vec5 0 -10 5 -10 2)]
        (begin
          (i64sort.sort! (&mut negative))
          (sort-test-assert-i64-vec5 negative -10 -10 0 2 5))))))

(cfg
  test
  (define (sort-test-assert-string-less-cases) : unit
    (begin
      (test.assert-true (string-less? "" "a") "empty string sorts first")
      (test.assert-true (string-less? "a" "aa") "prefix sorts first")
      (test.assert-true (string-less? "alpha" "beta") "alpha before beta")
      (test.assert-false (string-less? "beta" "alpha") "beta after alpha")
      (test.assert-false (string-less? "same" "same") "equal is not less"))))

(cfg
  test
  (define (sort-test-assert-string-sort-cases) : unit
    (begin
      (let
        [empty : strv.Vec (strv.new)]
        (begin
          (strsort.sort! (&mut empty) string-less?)
          (test.assert-i64-eq (strv.len (& empty)) 0 "empty string sort len")))
      (let
        [single : strv.Vec (sort-test-make-string-vec1 "solo")]
        (begin
          (strsort.sort! (&mut single) string-less?)
          (sort-test-assert-string-vec1 single "solo")))
      (let
        [sorted : strv.Vec
          (sort-test-make-string-vec4 "alpha" "bravo" "charlie" "delta")]
        (begin
          (strsort.sort! (&mut sorted) string-less?)
          (sort-test-assert-string-vec4
            sorted
            "alpha"
            "bravo"
            "charlie"
            "delta")))
      (let
        [mixed : strv.Vec
          (sort-test-make-string-vec4 "delta" "alpha" "charlie" "bravo")]
        (begin
          (strsort.sort! (&mut mixed) string-less?)
          (sort-test-assert-string-vec4 mixed "alpha" "bravo" "charlie" "delta")))
      (let
        [prefixes : strv.Vec (sort-test-make-string-vec4 "b" "aa" "a" "")]
        (begin
          (strsort.sort! (&mut prefixes) string-less?)
          (sort-test-assert-string-vec4 prefixes "" "a" "aa" "b")))
      (let
        [dupes : strv.Vec
          (sort-test-make-string-vec4 "beta" "alpha" "beta" "alpha")]
        (begin
          (strsort.sort! (&mut dupes) string-less?)
          (sort-test-assert-string-vec4 dupes "alpha" "alpha" "beta" "beta"))))))

(cfg
  test
  (define (sort-test-assert-pair-sort-stable) : unit
    (let
      [pairs : pairv.Vec (pairv.new)]
      (begin
        (pairv.push (&mut pairs) (SortPair 2 0))
        (pairv.push (&mut pairs) (SortPair 1 1))
        (pairv.push (&mut pairs) (SortPair 2 2))
        (pairv.push (&mut pairs) (SortPair 1 3))
        (pairsort.sort! (&mut pairs) sort-test-pair-less?)
        (test.assert-i64-eq
          (struct-get (pairv.get (& pairs) 0 (SortPair 0 -1)) seq)
          1
          "pair sort first equal keeps order")
        (test.assert-i64-eq
          (struct-get (pairv.get (& pairs) 1 (SortPair 0 -1)) seq)
          3
          "pair sort second equal keeps order")
        (test.assert-i64-eq
          (struct-get (pairv.get (& pairs) 2 (SortPair 0 -1)) seq)
          0
          "pair sort third equal keeps order")
        (test.assert-i64-eq
          (struct-get (pairv.get (& pairs) 3 (SortPair 0 -1)) seq)
          2
          "pair sort fourth equal keeps order")))))

(cfg
  test
  (define (sort-test-main) : i64
    (begin
      (sort-test-assert-i64-sort-cases)
      (sort-test-assert-string-less-cases)
      (sort-test-assert-string-sort-cases)
      (sort-test-assert-pair-sort-stable)
      42)))

(cfg
  test
  (test
    sort-api
    (test.assert-i64-eq (sort-test-main) 42 "sort-api fixture result")))