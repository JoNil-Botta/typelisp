;# Lifetime-scoped `i64` slice views for `stdlib/vector.tl`.
;#
;# `I64Slice` is a non-owning view over an `I64Vec` live prefix or an explicit
;# `(Array i64)` live prefix. The backing array handle is stored directly for
;# indexed reads, while a borrowed owner witness ties the view to the caller's
;# source lifetime.
(module stdlib.vector_slice)

(import stdlib.vector as vector_mod)

;: Lifetime witness for the source value that owns an `I64Slice` live range.
(comptime-decl
  (:generated vector-family I64SliceSource "i64")
  (defenum I64SliceSource
    (:lifetimes source)
    (I64SliceSourceVec (& source vector_mod.I64Vec))
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
    [v : vector_mod.I64Vec]
    [owner : (& source vector_mod.I64Vec)]) : (I64Slice source)
    (I64Slice
      (I64SliceSourceVec owner)
      (vector_mod.i64-vec-slots v)
      0
      (vector_mod.i64-vec-len v))))

;: Build a lifetime-scoped view over `v[start, start + len)`. Invalid ranges
;: return an empty view tied to `owner`; callers should pass `(& v)`.
(comptime-decl
  (:generated vector-family i64-slice-from-vec "i64")
  (define (i64-slice-from-vec
    [v : vector_mod.I64Vec]
    [owner : (& source vector_mod.I64Vec)]
    [start : i64]
    [len : i64]) : (I64Slice source)
    (if (stdlib.vector_slice.i64-slice-range-valid?
      (vector_mod.i64-vec-len v)
      start
      len)
      (I64Slice
        (I64SliceSourceVec owner)
        (vector_mod.i64-vec-slots v)
        start
        len)
      (I64Slice (I64SliceSourceVec owner) (vector_mod.i64-vec-slots v) 0 0))))

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
    (if (stdlib.vector_slice.i64-slice-live-count-valid? items count)
      (if (stdlib.vector_slice.i64-slice-range-valid? count start len)
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
    (<= (stdlib.vector_slice.i64-slice-len slice) 0)))

;: Read element `index` from the slice, returning `fallback` when out of range.
(comptime-decl
  (:generated vector-family i64-slice-get "i64")
  (define (i64-slice-get
    [slice : (I64Slice source)]
    [index : i64]
    [fallback : i64]) : i64
    (if (if (>= index 0)
      (< index (stdlib.vector_slice.i64-slice-len slice))
      false)
      (array-ref (struct-get slice slots) (+ (struct-get slice start) index))
      fallback)))

;: Build a sub-slice whose lifetime remains tied to the original source.
;: Invalid ranges return an empty view tied to the same source.
(comptime-decl
  (:generated vector-family i64-slice-sub-slice "i64")
  (define (i64-slice-sub-slice
    [slice : (I64Slice source)]
    [start : i64]
    [len : i64]) : (I64Slice source)
    (if (stdlib.vector_slice.i64-slice-range-valid?
      (stdlib.vector_slice.i64-slice-len slice)
      start
      len)
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
      [n : i64 (stdlib.vector_slice.i64-slice-len slice)]
      [out : (Array i64) (make-array i64 n)]
      [i : i64 0]
      (begin
        (while (< i n)
          (begin
            (array-set! out i (stdlib.vector_slice.i64-slice-get slice i 0))
            (set! i (+ i 1))))
        out))))

;: Copy the slice into a fresh `I64Vec`.
(comptime-decl
  (:generated vector-family i64-slice-to-vec "i64")
  (define (i64-slice-to-vec [slice : (I64Slice source)]) : vector_mod.I64Vec
    (vector_mod.i64-vec-from-array
      (stdlib.vector_slice.i64-slice-to-array slice)
      (stdlib.vector_slice.i64-slice-len slice))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value i64-slice-range-valid?)
  (value i64-slice-live-count-valid?)
  (value i64-slice-all-vec)
  (value i64-slice-from-vec)
  (value i64-slice-from-array)
  (value i64-slice-len)
  (value i64-slice-is-empty?)
  (value i64-slice-get)
  (value i64-slice-sub-slice)
  (value i64-slice-to-array)
  (value i64-slice-to-vec)
  (type I64SliceSource)
  (type I64Slice)
  (constructor I64Slice)
  (field I64Slice witness)
  (field I64Slice slots)
  (field I64Slice start)
  (field I64Slice len)
  (variant I64SliceSourceVec)
  (variant I64SliceSourceArray))