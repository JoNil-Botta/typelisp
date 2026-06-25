;# Iterator protocol conventions and scalar range iterators (#3514).
;#
;# TypeLisp does not use traits or generic interfaces for iterator dispatch.
;# The stdlib iterator protocol is a module-level convention for future macros:
;# a collection module exposes an `iterator` operation that returns iterator
;# state, and the iterator state's module exposes `next`, taking `&mut Iter` and
;# returning an option-like result. The current flat stdlib compatibility names
;# keep their module prefix, so this module's first concrete iterator is
;# `range` / `range-inclusive`, `i64-range-iterator`, and `i64-range-next`.
;#
;# `next` never uses sentinels, panics, or exceptions for exhaustion. It returns
;# a concrete `Done` variant, and repeated calls after exhaustion keep returning
;# `Done`. Migrating these monomorphic `*Next` enums to the generated
;# `(option T)` module belongs with the option user-migration work (#3214).
;#
;# ```typelisp
;# (import stdlib.iterator as iter)
;# (define (main) : i64
;#   (let
;#     [items : iter.I64Range (iter.range 0 3)]
;#     [it : iter.I64RangeIter (iter.i64-range-iterator items)]
;#     [sum : i64 0]
;#     [done : bool false]
;#     (begin
;#       (while (not done)
;#         (match (iter.i64-range-next (&mut it))
;#           [(iter.I64RangeItem value) (set! sum (+ sum value))]
;#           [(iter.I64RangeDone) (set! done true)]))
;#       sum)))
;# ```
(module stdlib.iterator)

;: Scalar `i64` range iterable. Half-open ranges yield `[start, end)`;
;: inclusive ranges yield `[start, end]`.
(defstruct I64Range
  (start i64)
  (end i64)
  (inclusive bool))

;: Iterator state for an `I64Range`.
(defstruct I64RangeIter
  (current i64)
  (end i64)
  (inclusive bool)
  (exhausted bool))

;: Option-like result returned by `i64-range-next`.
(defenum I64RangeNext
  (I64RangeDone)
  (I64RangeItem i64))

;: Build a scalar iterable over the half-open range `[start, end)`. Empty and
;: descending ranges are valid and yield no items.
(define (range [start : i64] [end : i64]) : I64Range
  (I64Range start end false))

;: Build a scalar iterable over the inclusive range `[start, end]`. Empty
;: descending ranges are valid and yield no items. The iterator state records
;: exhaustion directly, so an inclusive maximum `i64` endpoint is valid.
(define (range-inclusive [start : i64] [end : i64]) : I64Range
  (I64Range start end true))

;: Build an iterator for `items`.
(define (i64-range-iterator [items : I64Range]) : I64RangeIter
  (let
    [start : i64 (struct-get items start)]
    [end : i64 (struct-get items end)]
    [inclusive : bool (struct-get items inclusive)]
    [empty : bool
      (if inclusive
        (> start end)
        (>= start end))]
    (I64RangeIter start end inclusive empty)))

;: Return the next range item and advance the iterator, or `I64RangeDone` when
;: exhausted. Calling again after exhaustion returns `I64RangeDone`.
(define (i64-range-next [iter : (&mut iter I64RangeIter)]) : I64RangeNext
  (if (struct-get iter exhausted)
    (I64RangeDone)
    (let
      [current : i64 (struct-get iter current)]
      [end : i64 (struct-get iter end)]
      [inclusive : bool (struct-get iter inclusive)]
      (begin
        (if inclusive
          (if (= current end)
            (set! (struct-get iter exhausted) true)
            (set! (struct-get iter current) (+ current 1)))
          (let
            [next-current : i64 (+ current 1)]
            (begin
              (set! (struct-get iter current) next-current)
              (if (= next-current end)
                (set! (struct-get iter exhausted) true)
                (set! (struct-get iter exhausted) false)))))
        (I64RangeItem current)))))

;: Return true when a range next-result is exhausted.
(define (i64-range-done? [result : I64RangeNext]) : bool
  (match result
    [(I64RangeDone) true]
    [(I64RangeItem _) false]))

;: Return the yielded range item or `fallback` when the result is exhausted.
(define (i64-range-value-or [result : I64RangeNext] [fallback : i64]) : i64
  (match result
    [(I64RangeItem value) value]
    [(I64RangeDone) fallback]))

(cfg test (import stdlib.test))

(cfg
  test
  (define (iterator-test-range-sum [items : I64Range]) : i64
    (let
      [iter : I64RangeIter (i64-range-iterator items)]
      [sum : i64 0]
      [done : bool false]
      (begin
        (while (not done)
          (match (i64-range-next (&mut iter))
            [(I64RangeItem value) (set! sum (+ sum value))]
            [(I64RangeDone) (set! done true)]))
        sum))))

(cfg
  test
  (define (iterator-test-expect-next
    [iter : (&mut iter I64RangeIter)]
    [expected : i64]
    [message : String]) : unit
    (test.assert-i64-eq
      (i64-range-value-or (i64-range-next iter) -1)
      expected
      message)))

(cfg
  test
  (define (iterator-test-expect-done
    [iter : (&mut iter I64RangeIter)]
    [message : String]) : unit
    (test.assert-true (i64-range-done? (i64-range-next iter)) message)))

(cfg
  test
  (define (iterator-test-main) : i64
    (begin
      (test.assert-i64-eq
        (iterator-test-range-sum (range 0 0))
        0
        "empty range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range 5 3))
        0
        "descending range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range 4 5))
        4
        "single range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range 1 4))
        6
        "multi range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range-inclusive 1 3))
        6
        "inclusive range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range-inclusive 3 3))
        3
        "inclusive singleton sum")
      (test.assert-i64-eq
        (iterator-test-range-sum (range-inclusive 5 3))
        0
        "inclusive descending range sum")
      (let
        [iter : I64RangeIter (i64-range-iterator (range 7 8))]
        (begin
          (iterator-test-expect-next (&mut iter) 7 "first next yields value")
          (iterator-test-expect-done (&mut iter) "second next exhausted")
          (iterator-test-expect-done
            (&mut iter)
            "repeated next stays exhausted")))
      (let
        [iter : I64RangeIter
          (i64-range-iterator
            (range-inclusive 9223372036854775807 9223372036854775807))]
        (begin
          (iterator-test-expect-next
            (&mut iter)
            9223372036854775807
            "inclusive max endpoint yields")
          (iterator-test-expect-done
            (&mut iter)
            "inclusive max endpoint exhausts")
          (iterator-test-expect-done
            (&mut iter)
            "inclusive max endpoint repeated exhaustion")))
      42)))

(cfg
  test
  (test
    iterator-range-api
    (test.assert-i64-eq (iterator-test-main) 42 "iterator range fixture result")))