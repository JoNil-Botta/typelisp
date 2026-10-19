;; Selecting an inline field retains the logical element across buffer growth.
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct Nested
  (prefix i64)
  (inner Wide)
  (suffix i64))

(define trace : i64
  0)
(define selected : (__tl_dyn-array Pair)
  (__tl_make-array Pair 1))

(define (rebind-selected) : i64
  (set! selected (__tl_make-array Pair 1))
  (set! (array-ref selected 0) (Pair 30 40))
  70)

(define (index-once) : i64
  (set! trace (+ (* trace 10) 1))
  0)

(define (wide-growth [start : i64]) : i64
  (let
    [a : (__tl_dyn-array Wide) (__tl_make-array Wide 1)]
    [i : i64 start]
    (set! (array-ref a 0) (Wide 1 2 3 4))
    (set!
      (array-ref a i).b
      (begin
        (__tl_array-push! a (Wide 5 6 7 8))
        (set! i 1)
        70))
    (+ (* (array-ref a 0).b 100) (array-ref a 1).b)))

(define (pair-growth) : unit
  (let
    [a : (__tl_dyn-array Pair) (__tl_make-array Pair 1)]
    (set! (array-ref a 0) (Pair 1 2))
    (set! trace 0)
    (set!
      (array-ref a (index-once)).b
      (begin
        (set! trace (+ (* trace 10) 2))
        (__tl_array-push! a (Pair 3 4))
        70))
    (test.assert-i64-eq trace 12 "index once before value")
    (test.assert-i64-eq (array-ref a 0).a 1 "pair sibling field")
    (test.assert-i64-eq (array-ref a 0).b 70 "pair current buffer")
    (test.assert-i64-eq (array-ref a 1).b 4 "pair appended element")))

(define (nested-growth) : unit
  (let
    [a : (__tl_dyn-array Nested) (__tl_make-array Nested 1)]
    (set! (array-ref a 0) (Nested 10 (Wide 1 2 3 4) 20))
    (set!
      (array-ref a 0).inner.c
      (begin
        (__tl_array-push! a (Nested 30 (Wide 5 6 7 8) 40))
        70))
    (test.assert-i64-eq (array-ref a 0).inner.c 70 "nested current buffer")
    (test.assert-i64-eq (array-ref a 0).prefix 10 "nested prefix")
    (test.assert-i64-eq (array-ref a 0).suffix 20 "nested suffix")
    (test.assert-i64-eq (array-ref a 1).inner.c 7 "nested appended element")
    ;; No element bytes are read to select an inline field. The final store's
    ;; bounds check follows the value, which creates this logical element.
    (set!
      (array-ref a 2).inner.b
      (begin
        (__tl_array-push! a (Nested 50 (Wide 9 10 11 12) 60))
        80))
    (test.assert-i64-eq (array-ref a 2).inner.b 80 "new final logical index")))

(define (constructor-growth) : unit
  (let
    [a : (__tl_dyn-array Nested) (__tl_make-array Nested 1)]
    (set! (array-ref a 0) (Nested 10 (Wide 1 2 3 4) 20))
    (set!
      (array-ref a 0).inner
      (Wide
        (begin
          (__tl_array-push! a (Nested 30 (Wide 5 6 7 8) 40))
          70)
        80
        90
        100))
    (test.assert-i64-eq (array-ref a 0).inner.a 70 "direct field constructor")
    (test.assert-i64-eq (array-ref a 0).inner.d 100 "direct field last word")
    (test.assert-i64-eq (array-ref a 0).prefix 10 "direct field prefix")
    (test.assert-i64-eq (array-ref a 1).inner.a 5 "direct field growth effect")))

(define (receiver-rebinding) : unit
  (set! (array-ref selected 0) (Pair 1 2))
  (let
    [old : (Ptr Pair)
      (unsafe
        (ptr-cast (__tl_array-data selected) : (Ptr Pair)))]
    (set! (array-ref selected 0).b (rebind-selected))
    (test.assert-i64-eq (array-ref selected 0).b 40 "receiver binding effect")
    (test.assert-i64-eq
      (unsafe
        (ptr-read old)).b
      70
      "original descriptor"))
  (let
    [old : (Ptr Pair)
      (unsafe
        (ptr-cast (__tl_array-data selected) : (Ptr Pair)))]
    (set!
      (array-ref
        selected
        (begin
          (rebind-selected)
          0)).b
      80)
    (test.assert-i64-eq
      (array-ref selected 0).b
      40
      "receiver before index effects")
    (test.assert-i64-eq
      (unsafe
        (ptr-read old)).b
      80
      "original index receiver")))

(define (tuple-growth) : unit
  (let
    [a : (__tl_dyn-array (Tuple Pair i64)) (__tl_make-array (Tuple Pair i64) 1)]
    (set! (array-ref a 0) (tuple (Pair 1 2) 3))
    (set!
      (tuple-ref (array-ref a 0) 0).b
      (begin
        (__tl_array-push! a (tuple (Pair 4 5) 6))
        70))
    (test.assert-i64-eq (tuple-ref (array-ref a 0) 0).b 70 "tuple field chain")
    (test.assert-i64-eq (tuple-ref (array-ref a 1) 0).b 5 "tuple sibling")
    (set!
      (tuple-ref (array-ref a 0) 1)
      (begin
        (__tl_array-push! a (tuple (Pair 7 8) 9))
        80))
    (test.assert-i64-eq (tuple-ref (array-ref a 0) 1) 80 "tuple element field")))

(define (slice-fields [a : (&mut a (Slice Pair))]) : unit
  (let
    [i : i64 0]
    (set!
      (array-ref a i).b
      (begin
        (set! i 1)
        70))
    (test.assert-i64-eq i 1 "slice index effect")))

(define (main) : i64
  (test.assert-i64-eq (wide-growth 0) 7006 "reported four-word reproducer")
  (pair-growth)
  (nested-growth)
  (constructor-growth)
  (receiver-rebinding)
  (tuple-growth)
  (let
    [a : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (slice-fields (&mut a))
    (test.assert-i64-eq (array-ref a 0).b 70 "slice selected index")
    (test.assert-i64-eq (array-ref a 1).b 4 "slice sibling"))
  42)