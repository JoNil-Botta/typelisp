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
;# Usage: `(import stdlib.list)`
;#
;# ```typelisp
;# (import stdlib.list)
;# (define (main) : i64
;#   (list.string-list-count
;#     (list.string-list-builder-build
;#       (list.string-list-builder-push
;#         (list.string-list-builder-push (list.string-list-builder-empty) "first")
;#         "second"))))
;# ```
(module stdlib.list)

(import stdlib.vector as vector_mod)

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
  stdlib.list.StringNil)

;: Prepend `value` to `rest`.
(define (string-list-cons [value : String] [rest : StringList]) : StringList
  (StringCons value (box rest)))

;: Alias for `string-list-cons` for builder-style call sites.
(define (string-list-push-front [items : StringList] [value : String]) : StringList
  (StringCons value (box items)))

;: Return a one-element list.
(define (string-list-single [value : String]) : StringList
  (StringCons value (box stdlib.list.StringNil)))

;: Return the number of list nodes.
(define (string-list-count [items : StringList]) : i64
  (match items
    [(StringNil) 0]
    [(StringCons _ rest) (+ 1 (stdlib.list.string-list-count (box-get rest)))]))

;: Return true when `items` contains `value`.
(define (string-list-contains? [items : StringList] [value : String]) : bool
  (match items
    [(StringNil) false]
    [(StringCons head rest)
      (if (string-eq head value)
        true
        (stdlib.list.string-list-contains? (box-get rest) value))]))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (string-list-reverse-onto [items : StringList] [acc : StringList]) : StringList
  (match items
    [(StringNil) acc]
    [(StringCons head rest)
      (stdlib.list.string-list-reverse-onto
        (box-get rest)
        (StringCons head (box acc)))]))

;: Return `items` in reverse order.
(define (string-list-reverse [items : StringList]) : StringList
  (stdlib.list.string-list-reverse-onto items stdlib.list.StringNil))

;: Concatenate two lists while preserving order, allocating a fresh spine for
;: `left` and sharing `right` as the tail.
(define (string-list-append [left : StringList] [right : StringList]) : StringList
  (match left
    [(StringNil) right]
    [(StringCons head rest)
      (StringCons
        head
        (box (stdlib.list.string-list-append (box-get rest) right)))]))

;: Copy the first `count` array items into `acc` in reverse order, clamping the
;: count to the source array length.
(define (string-list-from-array-rev
  [src : (Array String)]
  [index : i64]
  [count : i64]
  [acc : StringList]) : StringList
  (if (>= index count)
    acc
    (stdlib.list.string-list-from-array-rev
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
    (stdlib.list.string-list-reverse
      (stdlib.list.string-list-from-array-rev src 0 n stdlib.list.StringNil))))

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
        (stdlib.list.string-list-to-array-fill (box-get rest) out (+ index 1)))]))

;: Return a fresh array containing exactly the list's items in order.
(define (string-list-to-array [items : StringList]) : (Array String)
  (let
    [n : i64 (stdlib.list.string-list-count items)]
    [out : (Array String) (make-array String n)]
    (begin
      (stdlib.list.string-list-to-array-fill items out 0)
      out)))

;: Build a list from `v`, preserving vector order.
(define (string-list-from-vec-from
  [v : vector_mod.StringVec]
  [index : i64]
  [acc : StringList]) : StringList
  (if (< index 0)
    acc
    (stdlib.list.string-list-from-vec-from
      v
      (- index 1)
      (StringCons (vector_mod.string-vec-get v index "") (box acc)))))

;: Build a list from `v`, preserving vector order.
(define (string-list-from-vec [v : vector_mod.StringVec]) : StringList
  (stdlib.list.string-list-from-vec-from
    v
    (- (vector_mod.string-vec-len v) 1)
    stdlib.list.StringNil))

;: Append `items` into `out` in order.
(define (string-list-to-vec-into
  [items : StringList]
  [out : vector_mod.StringVec]) : vector_mod.StringVec
  (match items
    [(StringNil) out]
    [(StringCons head rest)
      (stdlib.list.string-list-to-vec-into
        (box-get rest)
        (vector_mod.string-vec-push out head))]))

;: Copy `items` into a fresh `StringVec`, preserving list order.
(define (string-list-to-vec [items : StringList]) : vector_mod.StringVec
  (stdlib.list.string-list-to-vec-into
    items
    (vector_mod.string-vec-with-capacity (stdlib.list.string-list-count items))))

;: Return an empty builder.
(define (string-list-builder-empty) : StringListBuilder
  (StringListBuilder stdlib.list.StringNil))

;: Push `value` at the logical end of the builder.
(define (string-list-builder-push
  [builder : StringListBuilder]
  [value : String]) : StringListBuilder
  (StringListBuilder (StringCons value (box (struct-get builder items)))))

;: Return the number of values currently in `builder`.
(define (string-list-builder-count [builder : StringListBuilder]) : i64
  (stdlib.list.string-list-count (struct-get builder items)))

;: Build an ordered list from `builder`, followed by `tail`.
(define (string-list-builder-build-onto
  [builder : StringListBuilder]
  [tail : StringList]) : StringList
  (stdlib.list.string-list-reverse-onto (struct-get builder items) tail))

;: Build an ordered list from `builder`.
(define (string-list-builder-build [builder : StringListBuilder]) : StringList
  (stdlib.list.string-list-builder-build-onto builder stdlib.list.StringNil))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value string-list-empty)
  (value string-list-cons)
  (value string-list-push-front)
  (value string-list-single)
  (value string-list-count)
  (value string-list-contains?)
  (value string-list-reverse-onto)
  (value string-list-reverse)
  (value string-list-append)
  (value string-list-from-array-rev)
  (value string-list-from-array)
  (value string-list-to-array-fill)
  (value string-list-to-array)
  (value string-list-from-vec-from)
  (value string-list-from-vec)
  (value string-list-to-vec-into)
  (value string-list-to-vec)
  (value string-list-builder-empty)
  (value string-list-builder-push)
  (value string-list-builder-count)
  (value string-list-builder-build-onto)
  (value string-list-builder-build)
  (type StringList)
  (type StringListBuilder)
  (constructor StringListBuilder)
  (field StringListBuilder items)
  (variant StringNil)
  (variant StringCons))