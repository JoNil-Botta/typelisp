(defstruct Pair
  (x i64)
  (y i64))

(defstruct Wide
  (x i64)
  (y i64)
  (z i64))

(defstruct Bag
  (slots (Array i64 3))
  (pair Pair))

(define (field-write-score) : i64
  (let
    [item : Wide (Wide 10 20 5)]
    [field : (MutPtr i64)
      (unsafe
        (ptr-addr-of item.y))]
    (begin
      (unsafe
        (ptr-write! field 31))
      (+ item.x (+ item.y item.z)))))

(define (fixed-array-write-score [i : i64]) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [elem : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items i)))]
    (begin
      (unsafe
        (ptr-write! elem 44))
      (+ (array-ref items 0) (+ (array-ref items 1) (array-ref items 2))))))

(define (nested-place-write-score [i : i64]) : i64
  (let
    [bag : Bag (Bag (array 4 5 6) (Pair 7 8))]
    [field : (MutPtr i64)
      (unsafe
        (ptr-addr-of bag.pair.y))]
    [elem : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref bag.slots i)))]
    (begin
      (unsafe
        (ptr-write! field 9)
        (ptr-write! elem 70))
      (+ bag.pair.y (array-ref bag.slots i)))))

(define (dynamic-array-slot-read-score) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 40 40)]
    [slot : (MutPtr (__tl_dyn-array i64))
      (unsafe
        (ptr-addr-of items))]
    [copied : (__tl_dyn-array i64)
      (unsafe
        (ptr-read slot))]
    (+ (array-ref copied 0) (+ (array-ref copied 1) (array-length items)))))

(define (reference-slot-read-score [value : (& value i64)]) : i64
  (let
    [slot : (MutPtr (& value i64))
      (unsafe
        (ptr-addr-of value))]
    [copied : (& value i64)
      (unsafe
        (ptr-read slot))]
    (deref copied)))

(define (main) : i64
  (let
    [value : i64 9]
    (-
      (+
        (field-write-score)
        (+
          (fixed-array-write-score 1)
          (+
            (nested-place-write-score 2)
            (+
              (dynamic-array-slot-read-score)
              (reference-slot-read-score (& value))))))
      264)))