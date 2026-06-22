;# Iterator protocol conventions and scalar range iterators (#3514).
;#
;# TypeLisp does not use traits or generic interfaces for iterator dispatch.
;# The stdlib iterator protocol is a module-level convention for future macros:
;# a collection module exposes an `iterator` operation that returns iterator
;# state, and the iterator state's module exposes `next`, taking `&mut Iter` and
;# returning an option-like result. The current flat stdlib compatibility names
;# keep their module prefix, so this module's first concrete iterator is
;# `i64-range-iterator` plus `i64-range-next`.
;#
;# `next` never uses sentinels, panics, or exceptions for exhaustion. It returns
;# a concrete `Done` variant, and repeated calls after exhaustion keep returning
;# `Done`. The final generated `(option T)` module from #3203 should replace
;# these monomorphic `*Next` enums when it lands.
;#
;# ```typelisp
;# (import stdlib.iterator as iter)
;# (define (main) : i64
;#   (let
;#     [it : iter.I64RangeIter (iter.i64-range-iterator 0 3)]
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

;: Iterator state for a half-open `i64` range `[current, end)`.
(defstruct I64RangeIter
  (current i64)
  (end i64))

;: Option-like result returned by `i64-range-next`.
(defenum I64RangeNext
  (I64RangeDone)
  (I64RangeItem i64))

;: Build an iterator over the half-open range `[start, end)`. Empty and
;: descending ranges are valid and yield no items.
(define (i64-range-iterator [start : i64] [end : i64]) : I64RangeIter
  (I64RangeIter start end))

;: Return the next range item and advance the iterator, or `I64RangeDone` when
;: `current >= end`. Calling again after exhaustion returns `I64RangeDone`.
(define (i64-range-next [iter : (&mut iter I64RangeIter)]) : I64RangeNext
  (let
    [current : i64 (struct-get iter current)]
    (if (>= current (struct-get iter end))
      (I64RangeDone)
      (begin
        (set! (struct-get iter current) (+ current 1))
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
  (define (iterator-test-range-sum [start : i64] [end : i64]) : i64
    (let
      [iter : I64RangeIter (i64-range-iterator start end)]
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
  (define (iterator-test-main) : i64
    (begin
      (test.assert-i64-eq (iterator-test-range-sum 0 0) 0 "empty range sum")
      (test.assert-i64-eq
        (iterator-test-range-sum 5 3)
        0
        "descending range sum")
      (test.assert-i64-eq (iterator-test-range-sum 4 5) 4 "single range sum")
      (test.assert-i64-eq (iterator-test-range-sum 1 4) 6 "multi range sum")
      (let
        [iter : I64RangeIter (i64-range-iterator 7 8)]
        (begin
          (test.assert-i64-eq
            (i64-range-value-or (i64-range-next (&mut iter)) -1)
            7
            "first next yields value")
          (test.assert-true
            (i64-range-done? (i64-range-next (&mut iter)))
            "second next exhausted")
          (test.assert-true
            (i64-range-done? (i64-range-next (&mut iter)))
            "repeated next stays exhausted")))
      42)))

(cfg
  test
  (test
    iterator-range-api
    (test.assert-i64-eq (iterator-test-main) 42 "iterator range fixture result")))

(export
  (value i64-range-iterator)
  (value i64-range-next)
  (value i64-range-done?)
  (value i64-range-value-or)
  (type I64RangeIter)
  (type I64RangeNext)
  (constructor I64RangeIter)
  (field I64RangeIter current)
  (field I64RangeIter end)
  (variant I64RangeDone)
  (variant I64RangeItem))