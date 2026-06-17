;# stdlib/list.tl - Monomorphic string cons-list helpers (#1550).
;#
;# Provides the compatibility stdlib string cons-list surface. `StringList` is
;# an immutable cons list in insertion order; `StringListBuilder` stores pushed
;# values in reverse order and reverses once when built. New append-heavy private
;# code should prefer `StringVec` from `stdlib/vector.tl`; bridge helpers here
;# copy across the list/vector boundary for public compatibility wrappers.
;# List nodes, builder values, vectors, and arrays created by conversion helpers
;# allocate in the active arena.
;#
;# Usage: `(import "stdlib/list.tl")`
;#
;# ```typelisp
;# (import "stdlib/list.tl")
;# (define (main) : i64
;#   (string-list-count
;#     (string-list-builder-build
;#       (string-list-builder-push
;#         (string-list-builder-push (string-list-builder-empty) "first")
;#         "second"))))
;# ```
(import "vector.tl")

;: Immutable list of strings.
(defenum StringList
  (StringNil)
  (StringCons String (Box StringList)))

;: Builder for appending strings in call order. `items` is stored reversed so
;: each push is constant-time; build helpers allocate a fresh ordered spine.
(defstruct StringListBuilder
  (items StringList))

;: Return an empty string list.
(define (string-list-empty) : StringList
  (StringNil))

;: Prepend `value` to `rest`.
(define (string-list-cons [value : String] [rest : StringList]) : StringList
  (StringCons value (box rest)))

;: Alias for `string-list-cons` for builder-style call sites.
(define (string-list-push-front [items : StringList] [value : String]) : StringList
  (StringCons value (box items)))

;: Return a one-element list.
(define (string-list-single [value : String]) : StringList
  (StringCons value (box (StringNil))))

;: Return the number of list nodes.
(define (string-list-count [items : StringList]) : i64
  (match items
    [(StringNil) 0]
    [(StringCons _ rest) (+ 1 (string-list-count (box-get rest)))]))

;: Return true when `items` contains `value`.
(define (string-list-contains? [items : StringList] [value : String]) : bool
  (match items
    [(StringNil) false]
    [(StringCons head rest)
      (if (string-eq head value)
        true
        (string-list-contains? (box-get rest) value))]))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (string-list-reverse-onto [items : StringList] [acc : StringList]) : StringList
  (match items
    [(StringNil) acc]
    [(StringCons head rest)
      (string-list-reverse-onto (box-get rest) (StringCons head (box acc)))]))

;: Return `items` in reverse order.
(define (string-list-reverse [items : StringList]) : StringList
  (string-list-reverse-onto items (StringNil)))

;: Concatenate two lists while preserving order, allocating a fresh spine for
;: `left` and sharing `right` as the tail.
(define (string-list-append [left : StringList] [right : StringList]) : StringList
  (match left
    [(StringNil) right]
    [(StringCons head rest)
      (StringCons head (box (string-list-append (box-get rest) right)))]))

;: Copy the first `count` array items into `acc` in reverse order, clamping the
;: count to the source array length.
(define (string-list-from-array-rev
  [src : (Array String)]
  [index : i64]
  [count : i64]
  [acc : StringList]) : StringList
  (if (>= index count)
    acc
    (string-list-from-array-rev
      src
      (+ index 1)
      count
      (StringCons (array-ref src index) (box acc)))))

;: Build a list from the live prefix `[0, count)` of `src`. Negative counts
;: produce an empty list; counts past the source length are clamped.
(define (string-list-from-array [src : (Array String)] [count : i64]) : StringList
  (let
    [len : i64 (array-length src)]
    [n : i64
      (if (< count 0)
        0
        (if (> count len)
          len
          count))]
    (string-list-reverse (string-list-from-array-rev src 0 n (StringNil)))))

;: Fill `out` with `items` starting at `index`.
(define (string-list-to-array-fill
  [items : StringList]
  [out : (Array String)]
  [index : i64]) : unit
  (match items
    [(StringNil) unit]
    [(StringCons head rest)
      (begin
        (array-set! out index head)
        (string-list-to-array-fill (box-get rest) out (+ index 1)))]))

;: Return a fresh array containing exactly the list's items in order.
(define (string-list-to-array [items : StringList]) : (Array String)
  (let
    [n : i64 (string-list-count items)]
    [out : (Array String) (make-array String n)]
    (begin
      (string-list-to-array-fill items out 0)
      out)))

;: Build a list from `v`, preserving vector order.
(define (string-list-from-vec-from
  [v : StringVec]
  [index : i64]
  [acc : StringList]) : StringList
  (if (< index 0)
    acc
    (string-list-from-vec-from
      v
      (- index 1)
      (StringCons (string-vec-get v index "") (box acc)))))

;: Build a list from `v`, preserving vector order.
(define (string-list-from-vec [v : StringVec]) : StringList
  (string-list-from-vec-from v (- (string-vec-len v) 1) (StringNil)))

;: Append `items` into `out` in order.
(define (string-list-to-vec-into [items : StringList] [out : StringVec]) : StringVec
  (match items
    [(StringNil) out]
    [(StringCons head rest)
      (string-list-to-vec-into (box-get rest) (string-vec-push out head))]))

;: Copy `items` into a fresh `StringVec`, preserving list order.
(define (string-list-to-vec [items : StringList]) : StringVec
  (string-list-to-vec-into
    items
    (string-vec-with-capacity (string-list-count items))))

;: Return an empty builder.
(define (string-list-builder-empty) : StringListBuilder
  (StringListBuilder (StringNil)))

;: Push `value` at the logical end of the builder.
(define (string-list-builder-push
  [builder : StringListBuilder]
  [value : String]) : StringListBuilder
  (StringListBuilder (StringCons value (box (struct-get builder items)))))

;: Return the number of values currently in `builder`.
(define (string-list-builder-count [builder : StringListBuilder]) : i64
  (string-list-count (struct-get builder items)))

;: Build an ordered list from `builder`, followed by `tail`.
(define (string-list-builder-build-onto
  [builder : StringListBuilder]
  [tail : StringList]) : StringList
  (string-list-reverse-onto (struct-get builder items) tail))

;: Build an ordered list from `builder`.
(define (string-list-builder-build [builder : StringListBuilder]) : StringList
  (string-list-builder-build-onto builder (StringNil)))

;; Inline coverage migrated from stdlib/tests/list_api.tl (#3082).
(cfg test (import "test.tl"))

(cfg
  test
  (define (list-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (list-test-assert-string-list-empty
    [items : StringList]
    [message : String]) : unit
    (match items
      [(StringNil) unit]
      [_ (panic message)])))

(cfg
  test
  (define (list-test-assert-string-list1
    [items : StringList]
    [first : String]
    [message : String]) : unit
    (match items
      [(StringCons a rest)
        (match (box-get rest)
          [(StringNil) (list-test-assert-owned-string-eq a first message)]
          [_ (panic message)])]
      [_ (panic message)])))

(cfg
  test
  (define (list-test-assert-string-list3
    [items : StringList]
    [first : String]
    [second : String]
    [third : String]
    [message : String]) : unit
    (match items
      [(StringCons a rest)
        (match (box-get rest)
          [(StringCons b more)
            (match (box-get more)
              [(StringCons c tail)
                (match (box-get tail)
                  [(StringNil)
                    (begin
                      (list-test-assert-owned-string-eq a first message)
                      (list-test-assert-owned-string-eq b second message)
                      (list-test-assert-owned-string-eq c third message))]
                  [_ (panic message)])]
              [_ (panic message)])]
          [_ (panic message)])]
      [_ (panic message)])))

(cfg
  test
  (define (list-test-assert-string-list4
    [items : StringList]
    [first : String]
    [second : String]
    [third : String]
    [fourth : String]
    [message : String]) : unit
    (match items
      [(StringCons a rest)
        (match (box-get rest)
          [(StringCons b more)
            (match (box-get more)
              [(StringCons c tail)
                (match (box-get tail)
                  [(StringCons d end)
                    (match (box-get end)
                      [(StringNil)
                        (begin
                          (list-test-assert-owned-string-eq a first message)
                          (list-test-assert-owned-string-eq b second message)
                          (list-test-assert-owned-string-eq c third message)
                          (list-test-assert-owned-string-eq d fourth message))]
                      [_ (panic message)])]
                  [_ (panic message)])]
              [_ (panic message)])]
          [_ (panic message)])]
      [_ (panic message)])))

(cfg
  test
  (define (list-test-assert-string-array3
    [items : (Array String)]
    [first : String]
    [second : String]
    [third : String]
    [message : String]) : unit
    (begin
      (assert-i64-eq (array-length items) 3 message)
      (list-test-assert-owned-string-eq (array-ref items 0) first message)
      (list-test-assert-owned-string-eq (array-ref items 1) second message)
      (list-test-assert-owned-string-eq (array-ref items 2) third message))))

(cfg
  test
  (define (list-test-assert-string-vec3
    [items : StringVec]
    [first : String]
    [second : String]
    [third : String]
    [message : String]) : unit
    (begin
      (assert-i64-eq (string-vec-len items) 3 message)
      (list-test-assert-owned-string-eq
        (string-vec-get items 0 "missing")
        first
        message)
      (list-test-assert-owned-string-eq
        (string-vec-get items 1 "missing")
        second
        message)
      (list-test-assert-owned-string-eq
        (string-vec-get items 2 "missing")
        third
        message))))

(cfg
  test
  (define (list-test-make-source-array) : (Array String)
    (let
      [items : (Array String) (make-array String 4)]
      (begin
        (array-set! items 0 "red")
        (array-set! items 1 "green")
        (array-set! items 2 "blue")
        (array-set! items 3 "ignored")
        items))))

(cfg
  test
  (define (list-test-main) : i64
    (let
      [built : StringList
        (string-list-builder-build
          (string-list-builder-push
            (string-list-builder-push
              (string-list-builder-push (string-list-builder-empty) "alpha")
              "beta")
            "gamma"))]
      [source : (Array String) (list-test-make-source-array)]
      (begin
        (list-test-assert-string-list-empty
          (string-list-empty)
          "string-list empty")
        (list-test-assert-string-list1
          (string-list-single "one")
          "one"
          "string-list single")
        (assert-i64-eq
          (string-list-count (string-list-empty))
          0
          "string-list empty count")
        (assert-i64-eq
          (string-list-builder-count
            (string-list-builder-push (string-list-builder-empty) "one"))
          1
          "builder count")
        (assert-i64-eq (string-list-count built) 3 "string-list built count")
        (list-test-assert-string-list3
          built
          "alpha"
          "beta"
          "gamma"
          "builder order")
        (list-test-assert-string-list3
          (string-list-reverse
            (string-list-cons
              "third"
              (string-list-cons "second" (string-list-single "first"))))
          "first"
          "second"
          "third"
          "reverse order")
        (list-test-assert-string-list3
          (string-list-append
            (string-list-cons "left" (string-list-single "middle"))
            (string-list-single "right"))
          "left"
          "middle"
          "right"
          "append order")
        (assert-true
          (string-list-contains? built "beta")
          "contains reports existing item")
        (assert-false
          (string-list-contains? built "delta")
          "contains reports missing item")
        (list-test-assert-string-list3
          (string-list-builder-build-onto
            (string-list-builder-push (string-list-builder-empty) "head")
            (string-list-cons "tail1" (string-list-single "tail2")))
          "head"
          "tail1"
          "tail2"
          "build onto")
        (list-test-assert-string-list3
          (string-list-from-array source 3)
          "red"
          "green"
          "blue"
          "from array")
        (list-test-assert-string-list4
          (string-list-from-array source 99)
          "red"
          "green"
          "blue"
          "ignored"
          "from array clamp")
        (list-test-assert-string-list-empty
          (string-list-from-array source -1)
          "from array negative")
        (list-test-assert-string-array3
          (string-list-to-array built)
          "alpha"
          "beta"
          "gamma"
          "to array")
        (list-test-assert-string-vec3
          (string-list-to-vec built)
          "alpha"
          "beta"
          "gamma"
          "to vec")
        (list-test-assert-string-list3
          (string-list-from-vec (string-list-to-vec built))
          "alpha"
          "beta"
          "gamma"
          "from vec")
        42))))

(cfg
  test
  (test list-api (assert-i64-eq (list-test-main) 42 "list-api fixture result")))