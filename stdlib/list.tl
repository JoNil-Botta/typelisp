;# stdlib/list.tl - Monomorphic string cons-list helpers (#1550).
;#
;# Provides the first small stdlib list-builder surface while TypeLisp still
;# lacks comptime-generated generic collections. `StringList` is an immutable
;# cons list in insertion order; `StringListBuilder` stores pushed values in
;# reverse order and reverses once when built. List nodes, builder values, and
;# arrays created by conversion helpers allocate in the active arena.
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
;: Immutable list of strings.
(defenum StringList
  (StringNil)
  (StringCons String StringList))

;: Builder for appending strings in call order. `items` is stored reversed so
;: each push is constant-time; build helpers allocate a fresh ordered spine.
(defstruct StringListBuilder
  (items StringList))

;: Return an empty string list.
(define (string-list-empty) : StringList
  (StringNil))

;: Prepend `value` to `rest`.
(define (string-list-cons [value : String] [rest : StringList]) : StringList
  (StringCons value rest))

;: Alias for `string-list-cons` for builder-style call sites.
(define (string-list-push-front [items : StringList] [value : String]) : StringList
  (StringCons value items))

;: Return a one-element list.
(define (string-list-single [value : String]) : StringList
  (StringCons value (StringNil)))

;: Return the number of list nodes.
(define (string-list-count [items : StringList]) : i64
  (match items
    [(StringNil) 0]
    [(StringCons _ rest) (+ 1 (string-list-count rest))]))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (string-list-reverse-onto [items : StringList] [acc : StringList]) : StringList
  (match items
    [(StringNil) acc]
    [(StringCons head rest)
      (string-list-reverse-onto rest (StringCons head acc))]))

;: Return `items` in reverse order.
(define (string-list-reverse [items : StringList]) : StringList
  (string-list-reverse-onto items (StringNil)))

;: Concatenate two lists while preserving order, allocating a fresh spine for
;: `left` and sharing `right` as the tail.
(define (string-list-append [left : StringList] [right : StringList]) : StringList
  (match left
    [(StringNil) right]
    [(StringCons head rest) (StringCons head (string-list-append rest right))]))

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
      (StringCons (array-ref src index) acc))))

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
        (string-list-to-array-fill rest out (+ index 1)))]))

;: Return a fresh array containing exactly the list's items in order.
(define (string-list-to-array [items : StringList]) : (Array String)
  (let
    [n : i64 (string-list-count items)]
    [out : (Array String) (make-array String n)]
    (begin
      (string-list-to-array-fill items out 0)
      out)))

;: Return an empty builder.
(define (string-list-builder-empty) : StringListBuilder
  (StringListBuilder (StringNil)))

;: Push `value` at the logical end of the builder.
(define (string-list-builder-push
  [builder : StringListBuilder]
  [value : String]) : StringListBuilder
  (StringListBuilder (StringCons value (struct-get builder items))))

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