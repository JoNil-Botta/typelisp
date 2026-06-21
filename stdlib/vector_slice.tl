;# Lifetime-scoped `i64` slice views for `stdlib/vector.tl`.
;#
;# `I64Slice` is a non-owning view over an `I64Vec` live prefix or an explicit
;# `(Array i64)` live prefix. The backing array handle is stored directly for
;# indexed reads, while a borrowed owner witness ties the view to the caller's
;# source lifetime.
;#
;# The module also exposes the first slice-derived iterator for the stdlib
;# iterator protocol (#3514): `i64-slice-iterator` returns iterator state, and
;# `i64-slice-next` takes `&mut` state and returns an option-like
;# `I64SliceIterNext` value. The iterator snapshots the slice's
;# backing handle, start, and length, yields copied `i64` items, and exposes no
;# references. Exhaustion is explicit and stable: repeated `next` calls after
;# exhaustion keep returning `I64SliceIterDone`.
(module stdlib.vector_slice)

(import stdlib.vector)

;: Lifetime witness for the source value that owns an `I64Slice` live range.
(comptime-decl
  (:generated vector-family I64SliceSource "i64")
  (defenum I64SliceSource
    (:lifetimes source)
    (I64SliceSourceVec (& source vector.I64Vec))
    (I64SliceSourceArray (& source (Array i64)))))

;: Lifetime-scoped borrowed view over a live `I64Vec` or `(Array i64)` prefix.
;: Constructors take both the backing handle and a matching `(& source)` owner
;: witness because refs to arrays cannot be indexed directly in this slice.
(comptime-decl
  (:generated vector-family I64Slice "i64")
  (defstruct I64Slice
    (:lifetimes source)
    (witness (I64SliceSource source))
    (slots (Array i64))
    (start i64)
    (len i64)))

;: True when `start`/`len` describe a valid range inside `source-len`.
(comptime-decl
  (:generated vector-family i64-slice-range-valid? "i64")
  (define (i64-slice-range-valid? [source-len : i64] [start : i64] [len : i64]) : bool
    (let
      [non-negative-range? : bool
        (if (< start 0)
          false
          (if (< len 0)
            false
            true))]
      (if (< source-len 0)
        false
        (if non-negative-range?
          (if (> start source-len)
            false
            (<= len (- source-len start)))
          false)))))

;: True when an explicit array live count is inside the backing array.
(comptime-decl
  (:generated vector-family i64-slice-live-count-valid? "i64")
  (define (i64-slice-live-count-valid? [items : (Array i64)] [count : i64]) : bool
    (if (< count 0)
      false
      (<= count (array-length items)))))

;: View the whole live prefix of `v`; callers should pass `(& v)` as `owner`.
(comptime-decl
  (:generated vector-family i64-slice-all-vec "i64")
  (define (i64-slice-all-vec
    [v : vector.I64Vec]
    [owner : (& source vector.I64Vec)]) : (I64Slice source)
    (I64Slice
      (I64SliceSourceVec owner)
      (vector.i64-vec-slots v)
      0
      (vector.i64-vec-len v))))

;: Build a lifetime-scoped view over `v[start, start + len)`. Invalid ranges
;: return an empty view tied to `owner`; callers should pass `(& v)`.
(comptime-decl
  (:generated vector-family i64-slice-from-vec "i64")
  (define (i64-slice-from-vec
    [v : vector.I64Vec]
    [owner : (& source vector.I64Vec)]
    [start : i64]
    [len : i64]) : (I64Slice source)
    (if (i64-slice-range-valid? (vector.i64-vec-len v) start len)
      (I64Slice (I64SliceSourceVec owner) (vector.i64-vec-slots v) start len)
      (I64Slice (I64SliceSourceVec owner) (vector.i64-vec-slots v) 0 0))))

;: Build a lifetime-scoped view over `items[start, start + len)` inside the
;: explicit live prefix `[0, count)`. Invalid counts/ranges return an empty
;: view tied to `owner`; callers should pass `(& items)`.
(comptime-decl
  (:generated vector-family i64-slice-from-array "i64")
  (define (i64-slice-from-array
    [items : (Array i64)]
    [owner : (& source (Array i64))]
    [count : i64]
    [start : i64]
    [len : i64]) : (I64Slice source)
    (if (i64-slice-live-count-valid? items count)
      (if (i64-slice-range-valid? count start len)
        (I64Slice (I64SliceSourceArray owner) items start len)
        (I64Slice (I64SliceSourceArray owner) items 0 0))
      (I64Slice (I64SliceSourceArray owner) items 0 0))))

;: Number of live elements in the slice.
(comptime-decl
  (:generated vector-family i64-slice-len "i64")
  (define (i64-slice-len [slice : (I64Slice source)]) : i64
    (struct-get slice len)))

;: True when the slice contains no elements.
(comptime-decl
  (:generated vector-family i64-slice-is-empty? "i64")
  (define (i64-slice-is-empty? [slice : (I64Slice source)]) : bool
    (<= (i64-slice-len slice) 0)))

;: Read element `index` from the slice, returning `fallback` when out of range.
(comptime-decl
  (:generated vector-family i64-slice-get "i64")
  (define (i64-slice-get
    [slice : (I64Slice source)]
    [index : i64]
    [fallback : i64]) : i64
    (if (if (>= index 0)
      (< index (i64-slice-len slice))
      false)
      (array-ref (struct-get slice slots) (+ (struct-get slice start) index))
      fallback)))

;: Iterator state over an `I64Slice`. It snapshots the slice backing handle and
;: scalar range, then yields copied `i64` items without exposing references.
(comptime-decl
  (:generated vector-family I64SliceIter "i64")
  (defstruct I64SliceIter
    (slots (Array i64))
    (start i64)
    (len i64)
    (index i64)))

;: Option-like result returned by `i64-slice-next`.
(comptime-decl
  (:generated vector-family I64SliceIterNext "i64")
  (defenum I64SliceIterNext
    (I64SliceIterDone)
    (I64SliceIterItem i64)))

;: Build an iterator over `slice`. The iterator snapshots the backing range and
;: starts at element index 0.
(comptime-decl
  (:generated vector-family i64-slice-iterator "i64")
  (define (i64-slice-iterator [slice : (I64Slice source)]) : I64SliceIter
    (I64SliceIter
      (struct-get slice slots)
      (struct-get slice start)
      (struct-get slice len)
      0)))

;: Return the next slice item and advance `iter`, or `I64SliceIterDone` when all
;: items have been yielded. Calling again after exhaustion returns
;: `I64SliceIterDone`.
(comptime-decl
  (:generated vector-family i64-slice-next "i64")
  (define (i64-slice-next [iter : (&mut iter I64SliceIter)]) : I64SliceIterNext
    (let
      [index : i64 (struct-get iter index)]
      (if (>= index (struct-get iter len))
        (I64SliceIterDone)
        (let
          [value : i64
            (array-ref
              (struct-get iter slots)
              (+ (struct-get iter start) index))]
          (begin
            (set! (struct-get iter index) (+ index 1))
            (I64SliceIterItem value)))))))

;: Return true when a slice iterator next-result is exhausted.
(comptime-decl
  (:generated vector-family i64-slice-iter-done? "i64")
  (define (i64-slice-iter-done? [result : I64SliceIterNext]) : bool
    (match result
      [(I64SliceIterDone) true]
      [(I64SliceIterItem _) false])))

;: Return the yielded slice item or `fallback` when the result is exhausted.
(comptime-decl
  (:generated vector-family i64-slice-iter-value-or "i64")
  (define (i64-slice-iter-value-or [result : I64SliceIterNext] [fallback : i64]) : i64
    (match result
      [(I64SliceIterItem value) value]
      [(I64SliceIterDone) fallback])))

;: Build a sub-slice whose lifetime remains tied to the original source.
;: Invalid ranges return an empty view tied to the same source.
(comptime-decl
  (:generated vector-family i64-slice-sub-slice "i64")
  (define (i64-slice-sub-slice
    [slice : (I64Slice source)]
    [start : i64]
    [len : i64]) : (I64Slice source)
    (if (i64-slice-range-valid? (i64-slice-len slice) start len)
      (I64Slice
        (struct-get slice witness)
        (struct-get slice slots)
        (+ (struct-get slice start) start)
        len)
      (I64Slice
        (struct-get slice witness)
        (struct-get slice slots)
        (struct-get slice start)
        0))))

;: Copy the slice into a fresh `(Array i64)`.
(comptime-decl
  (:generated vector-family i64-slice-to-array "i64")
  (define (i64-slice-to-array [slice : (I64Slice source)]) : (Array i64)
    (let
      [n : i64 (i64-slice-len slice)]
      [out : (Array i64) (make-array i64 n)]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (array-set! out i (i64-slice-get slice i 0))
            (set! i (+ i 1))))
        out))))

;: Copy the slice into a fresh `I64Vec`.
(comptime-decl
  (:generated vector-family i64-slice-to-vec "i64")
  (define (i64-slice-to-vec [slice : (I64Slice source)]) : vector.I64Vec
    (vector.i64-vec-from-array (i64-slice-to-array slice) (i64-slice-len slice))))

;; Inline coverage migrated from stdlib/tests/vector_slice_check.tl (#3082).
(cfg test (import stdlib.test))

(cfg
  test
  (define (vector-slice-test-main) : unit
    (let
      [src : (Array i64) (make-array i64 3)]
      (begin
        (array-set! src 0 5)
        (array-set! src 1 6)
        (array-set! src 2 7)
        (let
          [fv : vector.I64Vec (vector.i64-vec-from-array src 3)]
          [full : (I64Slice fv) (i64-slice-all-vec fv (& fv))]
          [middle : (I64Slice fv) (i64-slice-from-vec fv (& fv) 1 2)]
          (begin
            (test.assert-i64-eq (i64-slice-len full) 3 "full slice len")
            (test.assert-i64-eq (i64-slice-len middle) 2 "middle slice len")
            (test.assert-false
              (i64-slice-is-empty? middle)
              "middle slice not empty")
            (test.assert-i64-eq
              (i64-slice-get middle 0 -1)
              6
              "middle slice first")
            (test.assert-i64-eq
              (i64-slice-get middle 1 -1)
              7
              "middle slice second")
            (test.assert-i64-eq
              (i64-slice-get middle 2 -1)
              -1
              "middle slice high fallback")
            (test.assert-i64-eq
              (i64-slice-get middle -1 -1)
              -1
              "middle slice negative fallback")
            (let
              [bad-start : (I64Slice fv) (i64-slice-from-vec fv (& fv) -1 1)]
              [bad-range : (I64Slice fv) (i64-slice-from-vec fv (& fv) 2 2)]
              (begin
                (test.assert-true
                  (i64-slice-is-empty? bad-start)
                  "slice negative start -> empty")
                (test.assert-true
                  (i64-slice-is-empty? bad-range)
                  "slice overrun -> empty")))
            (let
              [tail : (I64Slice fv) (i64-slice-sub-slice middle 1 1)]
              [bad-tail : (I64Slice fv) (i64-slice-sub-slice middle 1 2)]
              (begin
                (test.assert-i64-eq
                  (i64-slice-get tail 0 -1)
                  7
                  "sub-slice value")
                (test.assert-true
                  (i64-slice-is-empty? bad-tail)
                  "sub-slice overrun -> empty")))
            (let
              [from-array : (I64Slice src)
                (i64-slice-from-array src (& src) 3 0 2)]
              [bad-count : (I64Slice src)
                (i64-slice-from-array src (& src) 4 0 1)]
              [bad-array-range : (I64Slice src)
                (i64-slice-from-array src (& src) 3 1 3)]
              (begin
                (test.assert-i64-eq
                  (i64-slice-get from-array 1 -1)
                  6
                  "slice from array reads live prefix")
                (test.assert-true
                  (i64-slice-is-empty? bad-count)
                  "slice live count past array length -> empty")
                (test.assert-true
                  (i64-slice-is-empty? bad-array-range)
                  "slice array range past live count -> empty")))
            (let
              [slice-copy : (Array i64) (i64-slice-to-array middle)]
              [slice-vec : vector.I64Vec (i64-slice-to-vec middle)]
              (begin
                (test.assert-i64-eq
                  (array-length slice-copy)
                  2
                  "slice copy array length")
                (test.assert-i64-eq
                  (array-ref slice-copy 0)
                  6
                  "slice copy array first")
                (array-set! slice-copy 0 0)
                (test.assert-i64-eq
                  (i64-slice-get middle 0 -1)
                  6
                  "slice copy independent")
                (test.assert-i64-eq
                  (vector.i64-vec-len slice-vec)
                  2
                  "slice to vec len")
                (test.assert-i64-eq
                  (vector.i64-vec-get slice-vec 1 -1)
                  7
                  "slice to vec second")))
            (let
              [iter : I64SliceIter (i64-slice-iterator middle)]
              (begin
                (test.assert-i64-eq
                  (i64-slice-iter-value-or (i64-slice-next (&mut iter)) -1)
                  6
                  "slice iterator first")
                (test.assert-i64-eq
                  (i64-slice-iter-value-or (i64-slice-next (&mut iter)) -1)
                  7
                  "slice iterator second")
                (test.assert-true
                  (i64-slice-iter-done? (i64-slice-next (&mut iter)))
                  "slice iterator exhausted")
                (test.assert-true
                  (i64-slice-iter-done? (i64-slice-next (&mut iter)))
                  "slice iterator repeated exhaustion")))
            (let
              [empty-slice : (I64Slice fv) (i64-slice-from-vec fv (& fv) 2 2)]
              [empty-iter : I64SliceIter (i64-slice-iterator empty-slice)]
              (test.assert-true
                (i64-slice-iter-done? (i64-slice-next (&mut empty-iter)))
                "empty slice iterator exhausted"))))))))

(cfg
  test
  (test
    vector-slice-api
    (begin
      (vector-slice-test-main)
      unit)))

(export
  (value i64-slice-range-valid?)
  (value i64-slice-live-count-valid?)
  (value i64-slice-all-vec)
  (value i64-slice-from-vec)
  (value i64-slice-from-array)
  (value i64-slice-len)
  (value i64-slice-is-empty?)
  (value i64-slice-get)
  (value i64-slice-iterator)
  (value i64-slice-next)
  (value i64-slice-iter-done?)
  (value i64-slice-iter-value-or)
  (value i64-slice-sub-slice)
  (value i64-slice-to-array)
  (value i64-slice-to-vec)
  (type I64SliceSource)
  (type I64Slice)
  (type I64SliceIter)
  (type I64SliceIterNext)
  (constructor I64Slice)
  (constructor I64SliceIter)
  (field I64Slice witness)
  (field I64Slice slots)
  (field I64Slice start)
  (field I64Slice len)
  (field I64SliceIter slots)
  (field I64SliceIter start)
  (field I64SliceIter len)
  (field I64SliceIter index)
  (variant I64SliceSourceVec)
  (variant I64SliceSourceArray)
  (variant I64SliceIterDone)
  (variant I64SliceIterItem))