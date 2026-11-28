;; Integration coverage for inline 16-byte `{data_ptr, length}` DynArray and ZII (#7963).
(import stdlib.string)
(import stdlib.iterator)

(defstruct Bundle
  (tag i64)
  (name String)
  (items (__tl_dyn-array i64)))

(defenum Slot
  (Empty String (__tl_dyn-array i64) i64)
  (Filled (__tl_dyn-array i64)))

(define global-empty : (__tl_dyn-array i64)
  (__tl_make-array i64 0))
(define global-seeded : (__tl_dyn-array i64)
  (__tl_make-array i64 3))

(define (sum-slice [view : (& view (Slice i64))]) : i64
  (let
    [acc : i64 0]
    (for [x view]
      (+= acc (deref x)))
    acc))

(define (sum-dyn [xs : (& xs (__tl_dyn-array i64))]) : i64
  (let
    [acc : i64 0]
    (for [x xs]
      (+= acc (deref x)))
    acc))

(define (mutate-by-value [xs : (__tl_dyn-array i64)]) : i64
  (__tl_array-push! xs 99)
  (array-length xs))

(define (append-two! [xs : (&mut xs (__tl_dyn-array i64))] [a : i64] [b : i64]) : unit
  (__tl_array-push! xs a)
  (__tl_array-push! xs b))

(define (make-pair-buf [a : i64] [b : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (__tl_array-push! out a)
    (__tl_array-push! out b)
    out))

(define (main) : i64
  (when
    (not (= (comptime (size-of (type (__tl_dyn-array i64)))) 16))
    (return 1))
  (when
    (not (= (comptime (align-of (type (__tl_dyn-array i64)))) 8))
    (return 2))
  (when (not (= (comptime (size-of (type Bundle))) 40)) (return 3))
  ;; 1. Zero-initialized fixed array of (__tl_dyn-array i64): length 0, push, set, slice, iteration.
  (let
    [buckets : (Array (__tl_dyn-array i64) 3)
      (make-array (__tl_dyn-array i64) 3)]
    (for [i (iterator.range 0 3)]
      (when (not (= (array-length (array-ref buckets i)) 0)) (return 4))
      (when
        (not (= (length (slice-view (array-ref buckets i) 0 0)) 0))
        (return 5))
      (when (not (= (sum-dyn (& (array-ref buckets i))) 0)) (return 6)))
    (__tl_array-push! (array-ref buckets 1) 10)
    (__tl_array-push! (array-ref buckets 1) 20)
    (set! (array-ref (array-ref buckets 1) 0) 15)
    (when (not (= (array-length (array-ref buckets 1)) 2)) (return 7))
    (when (not (= (array-ref (array-ref buckets 1) 0) 15)) (return 8))
    (when (not (= (array-ref (array-ref buckets 1) 1) 20)) (return 9))
    (when
      (not (= (sum-slice (slice-view (array-ref buckets 1) 0 2)) 35))
      (return 10))
    (when (not (= (sum-dyn (& (array-ref buckets 1))) 35)) (return 11))
    ;; Sibling buckets stay zeroed and empty.
    (when (not (= (array-length (array-ref buckets 0)) 0)) (return 12))
    (when (not (= (array-length (array-ref buckets 2)) 0)) (return 13)))
  ;; 2. Zero-initialized struct combining String and DynArray fields.
  (let
    [bundles : (Array Bundle 2) (make-array Bundle 2)]
    (for [i (iterator.range 0 2)]
      (when (not (= (array-ref bundles i).tag 0)) (return 14))
      (when (not (string.eq (& (array-ref bundles i).name) "")) (return 15))
      (when (not (= (array-length (array-ref bundles i).items) 0)) (return 16)))
    (set! (array-ref bundles 0).tag 7)
    (set! (array-ref bundles 0).name "ok")
    (append-two! (&mut (array-ref bundles 0).items) 3 4)
    (when (not (= (array-ref bundles 0).tag 7)) (return 17))
    (when (not (string.eq (& (array-ref bundles 0).name) "ok")) (return 18))
    (when (not (= (sum-dyn (& (array-ref bundles 0).items)) 7)) (return 19))
    (when (not (= (array-length (array-ref bundles 1).items) 0)) (return 20)))
  ;; 3. Zero-initialized enum whose first variant carries String + DynArray.
  (let
    [slots : (Array Slot 2) (make-array Slot 2)]
    (for [i (iterator.range 0 2)]
      (match (& (array-ref slots i))
        [(Empty s xs n)
          (when
            (not (and (string.eq s "") (= (array-length xs) 0) (= n 0)))
            (return 21))]
        [(Filled _) (return 22)]))
    (set! (array-ref slots 0) (Filled (make-pair-buf 8 9)))
    (match (& (array-ref slots 0))
      [(Filled xs)
        (when
          (not (and (= (array-length xs) 2) (= (sum-dyn xs) 17)))
          (return 23))]
      [(Empty _ _ _) (return 24)]))
  ;; 4. Globals: inline zero-length and runtime-seeded dynamic arrays.
  (when (not (= (array-length global-empty) 0)) (return 25))
  (__tl_array-push! global-empty 5)
  (__tl_array-push! global-empty 6)
  (when (not (= (sum-dyn (& global-empty)) 11)) (return 26))
  (set! (array-ref global-seeded 2) 12)
  (when (not (= (array-ref global-seeded 2) 12)) (return 27))
  ;; 5. By-value return (sret), by-value param mutation, and closure capture.
  (let
    [built : (__tl_dyn-array i64) (make-pair-buf 1 2)]
    [cloned : (__tl_dyn-array i64) (make-pair-buf 4 5)]
    [f : (-> i64)
      (lambda () : i64
        (sum-dyn (& cloned)))]
    (when (not (= (mutate-by-value built) 3)) (return 28))
    (when (not (= (f) 9)) (return 29)))
  42)