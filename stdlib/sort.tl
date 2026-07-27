;# Stable deterministic sort helpers for generated stdlib vectors.
;#
;# This module follows the generated concrete collection model. `(vec T)`
;# emits a module that sorts the matching `(vector T)` module's `Vec` in place.
;# Scalar element types with a built-in `<` get `sort!`; non-scalar element
;# types get `sort!` with an explicit caller-supplied `less?` comparator.
;#
;# Generated sorts use a stable bottom-up merge sort. Runs of at most 16
;# elements use insertion sort; larger inputs allocate one `len`-element
;# scratch array in the active arena. Only the live prefix `[0, len)` of the
;# existing backing array is mutated.
;#
;# Usage: `(import stdlib.sort)`
;#
;# ```typelisp
;# (import stdlib.vector)
;# (import stdlib.sort)
;#
;# (import (stdlib.vector.vector i64) as ivec)
;# (import (stdlib.sort.vec i64) as isort)
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
(import stdlib.comptime)

;; lint-allow: unused-import
(import stdlib.string)

;; lint-allow: unused-import
(import stdlib.vector)

;: Return the character code at `idx` in borrowed text.
(define (char-code-at [text : (& text str)] [idx : i64]) : i64
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
          [lc : i64 (stdlib.sort.char-code-at left idx)]
          [rc : i64 (stdlib.sort.char-code-at right idx)]
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

;: Emit a stable ascending merge-sort module for `(vector T)`.
;:
;: Scalar element types expose `(sort! (&mut v))` and compare with the built-in
;: `<`. Non-scalar element types expose `(sort! (&mut v) less?)`, where `less?`
;: has type `(-> T T bool)` and returns true when the first value should sort
;: before the second. Inputs of 16 elements or fewer use stable insertion sort
;: without allocating. Larger inputs use stable bottom-up merging with O(n)
;: active-arena scratch storage and O(n log n) worst-case comparisons.
(defmacro (vec [T : type]) : Module
  (let
    [type-key-name : String (type-key T)]
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "stdlib.vector.generated." type-key-name))]
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
    [insertion-less : comptime.Expr
      (if scalar?
        `(< value (array-ref slots (- j 1)))
        `(less? (clone value) (clone (array-ref slots (- j 1)))))]
    [insertion-shift-value : comptime.Expr
      (if scalar?
        `(array-ref slots (- j 1))
        `(clone (array-ref slots (- j 1))))]
    [boundary-less : comptime.Expr
      (if scalar?
        `(< (array-ref slots mid) (array-ref slots (- mid 1)))
        `(less?
          (clone (array-ref slots mid))
          (clone (array-ref slots (- mid 1)))))]
    [right-before-left : comptime.Expr
      (if scalar?
        `(< (array-ref slots right-index) (array-ref slots left-index))
        `(less?
          (clone (array-ref slots right-index))
          (clone (array-ref slots left-index))))]
    [left-merge-value : comptime.Expr
      (if scalar?
        `(array-ref slots left-index)
        `(clone (array-ref slots left-index)))]
    [right-merge-value : comptime.Expr
      (if scalar?
        `(array-ref slots right-index)
        `(clone (array-ref slots right-index)))]
    [copy-back-value : comptime.Expr
      (if scalar?
        `(array-ref scratch out)
        `(clone (array-ref scratch out)))]
    [sort-body : comptime.Expr
      `(let
        [n : i64 (len-mut v)]
        [slots (slots-mut v)]
        [chunk-start : i64 0]
        (begin
          (while (< chunk-start n)
            (let
              [chunk-end : i64
                (if (> 16 (- n chunk-start))
                  n
                  (+ chunk-start 16))]
              [i : i64 (+ chunk-start 1)]
              (begin
                (while (< i chunk-end)
                  (let
                    [value : ,T (array-ref slots i)]
                    [j : i64 i]
                    (begin
                      (while (if (> j chunk-start)
                        ,insertion-less
                        false)
                        (begin
                          (array-set! slots j ,insertion-shift-value)
                          (set! j (- j 1))))
                      (array-set! slots j value)
                      (set! i (+ i 1)))))
                (set! chunk-start chunk-end))))
          (if (> n 16)
            (let
              [scratch : (__tl_dyn-array ,T) (make-array ,T n)]
              [width : i64 16]
              (while (< width n)
                (let
                  [left : i64 0]
                  (begin
                    (while (< left n)
                      (let
                        [mid : i64
                          (if (> width (- n left))
                            n
                            (+ left width))]
                        [right : i64
                          (if (> width (- n mid))
                            n
                            (+ mid width))]
                        (begin
                          (if (if (< mid right)
                            ,boundary-less
                            false)
                            (let
                              [left-index : i64 left]
                              [right-index : i64 mid]
                              [out : i64 left]
                              (begin
                                (while (< out right)
                                  (let
                                    [take-left : bool
                                      (if (< left-index mid)
                                        (if (< right-index right)
                                          (not ,right-before-left)
                                          true)
                                        false)]
                                    (begin
                                      (if take-left
                                        (begin
                                          (array-set!
                                            scratch
                                            out
                                            ,left-merge-value)
                                          (set! left-index (+ left-index 1)))
                                        (begin
                                          (array-set!
                                            scratch
                                            out
                                            ,right-merge-value)
                                          (set! right-index (+ right-index 1))))
                                      (set! out (+ out 1)))))
                                (set! out left)
                                (while (< out right)
                                  (begin
                                    (array-set! slots out ,copy-back-value)
                                    (set! out (+ out 1))))))
                            unit)
                          (set! left right))))
                    (set!
                      width
                      (if (>= width (- n width))
                        n
                        (* width 2)))))))
            unit)))]
    [sort-decl : comptime.Expr
      (if scalar?
        `(define (sort! [v : (&mut v Vec)]) : unit
          ,sort-body)
        `(define (sort! [v : (&mut v Vec)] [less? : (-> ,T ,T bool)]) : unit
          ,sort-body))]
    `(begin
      (module ,module-name)
      (import stdlib.array)
      ,sort-decl)))

;; Inline test coverage.
(cfg
  test
  (defstruct SortTestItem
    (key i64)
    (order i64)))

(cfg test (import stdlib.test))
(cfg test (import (stdlib.vector.vector i64) as i64v))
(cfg test (import (stdlib.sort.vec i64) as i64sort))
(cfg test (import (stdlib.sort.vec i64) as i64sort_again))
(cfg test (import (stdlib.vector.vector String) as strv))
(cfg test (import (stdlib.sort.vec String) as strsort))
(cfg test (import (stdlib.vector.vector SortTestItem) as itemv))
(cfg test (import (stdlib.sort.vec SortTestItem) as itemsort))

(cfg
  test
  (define (sort-test-first-char-less? [left : String] [right : String]) : bool
    (<
      (stdlib.sort.char-code-at (& left) 0)
      (stdlib.sort.char-code-at (& right) 0))))

(cfg
  test
  (define sort-test-comparison-count : i64
    0))

(cfg
  test
  (define (sort-test-counting-string-less? [left : String] [right : String]) : bool
    (begin
      (set! sort-test-comparison-count (+ sort-test-comparison-count 1))
      (stdlib.sort.string-less? left right))))

(cfg
  test
  (define (sort-test-item-less? [left : SortTestItem] [right : SortTestItem]) : bool
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
  (define (sort-test-assert-large-i64-sort) : unit
    (let
      [items : i64v.Vec (i64v.new)]
      [i : i64 0]
      (begin
        (while (< i 2049)
          (begin
            (i64v.push (&mut items) (- 2048 i))
            (set! i (+ i 1))))
        (i64sort.sort! (&mut items))
        (test.assert-i64-eq (i64v.len (& items)) 2049 "large i64 sort len")
        (set! i 0)
        (while (< i 2049)
          (begin
            (test.assert-i64-eq
              (i64v.get (& items) i -1)
              i
              "large i64 sort item")
            (set! i (+ i 1))))))))

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
  (define (sort-test-assert-string-sort-stable) : unit
    (let
      [items : strv.Vec (strv.new)]
      (begin
        (strv.push (&mut items) "b0")
        (strv.push (&mut items) "a1")
        (strv.push (&mut items) "b2")
        (strv.push (&mut items) "a3")
        (strsort.sort! (&mut items) sort-test-first-char-less?)
        (sort-test-assert-string-vec4 items "a1" "a3" "b0" "b2")))))

(cfg
  test
  (define (sort-test-assert-merge-sort-stable) : unit
    (let
      [items : strv.Vec (strv.new)]
      (begin
        (strv.push (&mut items) "b0")
        (strv.push (&mut items) "a1")
        (strv.push (&mut items) "b2")
        (strv.push (&mut items) "a3")
        (strv.push (&mut items) "b4")
        (strv.push (&mut items) "a5")
        (strv.push (&mut items) "b6")
        (strv.push (&mut items) "a7")
        (strv.push (&mut items) "b8")
        (strv.push (&mut items) "a9")
        (strv.push (&mut items) "b10")
        (strv.push (&mut items) "a11")
        (strv.push (&mut items) "b12")
        (strv.push (&mut items) "a13")
        (strv.push (&mut items) "b14")
        (strv.push (&mut items) "a15")
        (strv.push (&mut items) "b16")
        (strv.push (&mut items) "a17")
        (strv.push (&mut items) "b18")
        (strv.push (&mut items) "a19")
        (strv.push (&mut items) "b20")
        (strv.push (&mut items) "a21")
        (strv.push (&mut items) "b22")
        (strv.push (&mut items) "a23")
        (strv.push (&mut items) "b24")
        (strv.push (&mut items) "a25")
        (strv.push (&mut items) "b26")
        (strv.push (&mut items) "a27")
        (strv.push (&mut items) "b28")
        (strv.push (&mut items) "a29")
        (strv.push (&mut items) "b30")
        (strv.push (&mut items) "a31")
        (strsort.sort! (&mut items) sort-test-first-char-less?)
        (test.assert-i64-eq (strv.len (& items)) 32 "merge stability len")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 0 "missing")
          "a1"
          "merge stability a first")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 7 "missing")
          "a15"
          "merge stability a left run")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 8 "missing")
          "a17"
          "merge stability a right run")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 15 "missing")
          "a31"
          "merge stability a last")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 16 "missing")
          "b0"
          "merge stability b first")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 23 "missing")
          "b14"
          "merge stability b left run")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 24 "missing")
          "b16"
          "merge stability b right run")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 31 "missing")
          "b30"
          "merge stability b last")))))

(cfg
  test
  (define (sort-test-assert-comparison-growth) : unit
    (let
      [items : strv.Vec (strv.new)]
      [i : i64 0]
      (begin
        (while (< i 512)
          (begin
            (strv.push
              (&mut items)
              (if (< i 256)
                "b"
                "a"))
            (set! i (+ i 1))))
        (set! sort-test-comparison-count 0)
        (strsort.sort! (&mut items) sort-test-counting-string-less?)
        (test.assert-true
          (< sort-test-comparison-count 8192)
          "large sort comparison count stays subquadratic")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 0 "missing")
          "a"
          "large comparator sort first")
        (sort-test-assert-owned-string-eq
          (strv.get (& items) 511 "missing")
          "b"
          "large comparator sort last")))))

(cfg
  test
  (define (sort-test-assert-aggregate-merge-stable) : unit
    (let
      [items : itemv.Vec (itemv.new)]
      [i : i64 0]
      (begin
        (while (< i 32)
          (begin
            (itemv.push (&mut items) (SortTestItem (% i 4) i))
            (set! i (+ i 1))))
        (itemsort.sort! (&mut items) sort-test-item-less?)
        (test.assert-i64-eq (itemv.len (& items)) 32 "aggregate sort len")
        (set! i 0)
        (while (< i 32)
          (let
            [item : SortTestItem (itemv.get (& items) i (SortTestItem -1 -1))]
            [expected-key : i64 (/ i 8)]
            [expected-order : i64 (+ expected-key (* (% i 8) 4))]
            (begin
              (test.assert-i64-eq
                (struct-get item key)
                expected-key
                "aggregate sort key")
              (test.assert-i64-eq
                (struct-get item order)
                expected-order
                "aggregate sort stable order")
              (set! i (+ i 1)))))))))

(cfg
  test
  (define (sort-test-main) : i64
    (begin
      (sort-test-assert-i64-sort-cases)
      (sort-test-assert-large-i64-sort)
      (sort-test-assert-string-less-cases)
      (sort-test-assert-string-sort-cases)
      (sort-test-assert-string-sort-stable)
      (sort-test-assert-merge-sort-stable)
      (sort-test-assert-comparison-growth)
      (sort-test-assert-aggregate-merge-stable)
      42)))

(cfg
  test
  (test
    sort-api
    (test.assert-i64-eq (sort-test-main) 42 "sort-api fixture result")))