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
        (ptr-addr-of (struct-get item y)))]
    (begin
      (unsafe
        (ptr-write! field 31))
      (+ (struct-get item x) (+ (struct-get item y) (struct-get item z))))))

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
        (ptr-addr-of (struct-get (struct-get bag pair) y)))]
    [elem : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref (struct-get bag slots) i)))]
    (begin
      (unsafe
        (ptr-write! field 9)
        (ptr-write! elem 70))
      (+
        (struct-get (struct-get bag pair) y)
        (array-ref (struct-get bag slots) i)))))

(define (main) : i64
  (-
    (+
      (field-write-score)
      (+ (fixed-array-write-score 1) (nested-place-write-score 2)))
    173))