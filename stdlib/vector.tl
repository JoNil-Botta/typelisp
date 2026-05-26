;;;; Dynamic `i64` vector (collections v1, #835).
;;;;
;;;; A growable, owned sequence of `i64` built on the fixed `(Array i64)`
;;;; primitive: a backing array plus a live-element count (`len`). Capacity is
;;;; the backing array length; `push` doubles the backing array when it is full,
;;;; copying the live prefix into the larger array. This is the first of the
;;;; post-HashMap collection family (#835): a monomorphic, handwritten v1 that
;;;; does not wait for comptime-generated generics (#483/#817).
;;;;
;;;; Mutating operations thread the vector forward (like `stdlib/hashmap.tl`):
;;;; `set!` mutates the backing array in place and returns the same vector, while
;;;; `push`/`pop` may reallocate, so callers must use the returned vector. Reads
;;;; are bounds-checked and return a caller-supplied fallback rather than
;;;; panicking, so the module typechecks on every stage0 regardless of the
;;;; never-type.
;;;;
;;;; Usage: `(import "stdlib/vector.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/vector.tl")
;;;; (define (main) : i64
;;;;   (let
;;;;     [v : I64Vec (i64-vec-push (i64-vec-push (i64-vec-new) 10) 32)]
;;;;     (+ (i64-vec-get v 0 0) (i64-vec-get v 1 0))))
;;;; ```

;;; A growable `i64` sequence: the backing array and the number of live
;;; elements stored in its prefix `[0, len)`. Capacity is `(array-length slots)`.
(defstruct I64Vec
  (slots (Array i64))
  (len i64))

;;; Result of `i64-vec-pop`: the removed last element together with the shrunk
;;; vector, or `Empty` when the vector had no elements.
(defenum I64VecPop
  (I64VecPopEmpty)
  (I64VecPopOk i64 I64Vec))

;;; The vector's backing array. Only the prefix `[0, len)` holds live elements.
(define (i64-vec-slots [v : I64Vec]) : (Array i64)
  (struct-get v slots))

;;; Number of live elements.
(define (i64-vec-len [v : I64Vec]) : i64
  (struct-get v len))

;;; Number of slots in the backing array (the current capacity).
(define (i64-vec-capacity [v : I64Vec]) : i64
  (array-length (struct-get v slots)))

;;; True when the vector holds no live elements.
(define (i64-vec-is-empty? [v : I64Vec]) : bool
  (<= (i64-vec-len v) 0))

;;; Create an empty vector with backing capacity `capacity`. A non-positive
;;; capacity is clamped to 1 so the backing array can always grow by doubling.
(define (i64-vec-with-capacity [capacity : i64]) : I64Vec
  (let
    [cap : i64 (if (< capacity 1) 1 capacity)]
    (I64Vec (make-array i64 cap) 0)))

;;; Create an empty vector with a small default capacity.
(define (i64-vec-new) : I64Vec
  (i64-vec-with-capacity 4))

;;; Read element `index`, returning `fallback` when `index` is out of the live
;;; range `[0, len)`.
(define (i64-vec-get [v : I64Vec] [index : i64] [fallback : i64]) : i64
  (if (if (>= index 0)
    (< index (i64-vec-len v))
    false)
    (array-ref (i64-vec-slots v) index)
    fallback))

;;; Read the last live element, or `fallback` when the vector is empty.
(define (i64-vec-last [v : I64Vec] [fallback : i64]) : i64
  (i64-vec-get v (- (i64-vec-len v) 1) fallback))

;;; Overwrite element `index` in place when it is within `[0, len)`; otherwise
;;; leave the vector unchanged. Returns the same vector either way.
(define (i64-vec-set! [v : I64Vec] [index : i64] [value : i64]) : I64Vec
  (begin
    (if (if (>= index 0)
      (< index (i64-vec-len v))
      false)
      (array-set! (i64-vec-slots v) index value)
      unit)
    v))

;;; Copy elements `[index, count)` from `src` into `dst`.
(define (i64-vec-copy-range
  [dst : (Array i64)]
  [src : (Array i64)]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (i64-vec-copy-range dst src (+ index 1) count))))

;;; Return a copy of `v` whose backing array is twice as large, preserving the
;;; live prefix. Capacity is always positive (see `i64-vec-with-capacity`), so
;;; doubling strictly grows the array.
(define (i64-vec-grow [v : I64Vec]) : I64Vec
  (let
    [n : i64 (i64-vec-len v)]
    [bigger : (Array i64) (make-array i64 (* (i64-vec-capacity v) 2))]
    (begin
      (i64-vec-copy-range bigger (i64-vec-slots v) 0 n)
      (I64Vec bigger n))))

;;; Append `value` to the end, growing the backing array first when it is full.
;;; Returns the updated vector, which callers must thread forward because a push
;;; that grows reallocates the backing array.
(define (i64-vec-push [v : I64Vec] [value : i64]) : I64Vec
  (if (< (i64-vec-len v) (i64-vec-capacity v))
    (let
      [slots : (Array i64) (i64-vec-slots v)]
      (begin
        (array-set! slots (i64-vec-len v) value)
        (I64Vec slots (+ (i64-vec-len v) 1))))
    (i64-vec-push (i64-vec-grow v) value)))

;;; Remove and return the last element together with the shrunk vector, or
;;; `Empty` when the vector has no elements. The backing array is shared with the
;;; input vector (only `len` shrinks), so do not keep using the popped vector.
(define (i64-vec-pop [v : I64Vec]) : I64VecPop
  (if (<= (i64-vec-len v) 0)
    (I64VecPopEmpty)
    (let
      [last-index : i64 (- (i64-vec-len v) 1)]
      (I64VecPopOk
        (array-ref (i64-vec-slots v) last-index)
        (I64Vec (i64-vec-slots v) last-index)))))
