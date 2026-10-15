;; Receiver and index selection precede the value; store validation follows it.
(import stdlib.test)
(import stdlib.string)

(define global-array : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

(define (rebind-global-array) : i64
  (set! global-array (__tl_make-array i64 1))
  (set! (array-ref global-array 0) 30)
  7)

(define (global-receiver-rebind) : unit
  (set! (array-ref global-array 0) 10)
  (let
    [old : (Ptr i64)
      (unsafe
        (ptr-cast (__tl_array-data global-array) : (Ptr i64)))]
    (set! (array-ref global-array 0) (rebind-global-array))
    (test.assert-i64-eq
      (array-ref global-array 0)
      30
      "global binding write retained")
    (test.assert-i64-eq
      (unsafe
        (ptr-read old))
      7
      "selected global receiver value")))

(define trace : i64
  0)
(define global-index : i64
  0)

(define (mark [digit : i64]) : i64
  (set! trace (+ (* trace 10) digit))
  0)

(define (move-index) : i64
  (set! global-index 1)
  7)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (set-through-slice [a : (&mut a (Slice i64))]) : unit
  (let
    [index : i64 0]
    (set!
      (array-ref a index)
      (begin
        (set! index 1)
        7))
    (test.assert-i64-eq index 1 "slice index write")))

(define (receiver-index-rebind) : unit
  (let
    [a : (Array i64 1) (array 10)]
    [b : (Array i64 1) (array 30)]
    (set!
      (array-ref
        a
        (begin
          (set! a b)
          0))
      7)
    (test.assert-i64-eq
      (array-ref a 0)
      30
      "receiver value precedes index effects")))

(define (growth-in-value) : unit
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [index : i64 0]
    (set! (array-ref a 0) 10)
    (set!
      (array-ref a index)
      (begin
        (__tl_array-push! a 99)
        (set! index 1)
        7))
    (test.assert-i64-eq
      (array-ref a 0)
      7
      "selected logical element after growth")
    (test.assert-i64-eq (array-ref a 1) 99 "growth effect retained")
    (test.assert-i64-eq index 1 "index mutation retained"))
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (set!
      (array-ref a 1)
      (begin
        (__tl_array-push! a 99)
        7))
    (test.assert-i64-eq (array-ref a 1) 7 "bounds checked at the final store")))

(define (aggregate-growth-in-value) : unit
  (let
    [a : (__tl_dyn-array Wide) (__tl_make-array Wide 1)]
    (set! (array-ref a 0) (Wide 1 2 3 4))
    (set!
      (array-ref a 0)
      (Wide
        (begin
          (__tl_array-push! a (Wide 5 6 7 8))
          9)
        10
        11
        12))
    (test.assert-i64-eq
      (array-ref a 0).a
      9
      "constructor targets current buffer")
    (test.assert-i64-eq (array-ref a 0).d 12 "constructor last field")
    (test.assert-i64-eq (array-ref a 1).a 5 "constructor growth effect")))

(define (main) : i64
  (global-receiver-rebind)
  (aggregate-growth-in-value)
  (growth-in-value)
  (receiver-index-rebind)
  (let
    [a : (Array i64 2) (array 10 20)]
    [index : i64 0]
    (set!
      (array-ref a index)
      (begin
        (set! index 1)
        7))
    (test.assert-i64-eq (array-ref a 0) 7 "original index")
    (test.assert-i64-eq (array-ref a 1) 20 "untouched sibling")
    (test.assert-i64-eq index 1 "index write"))
  (let
    [a : (Array i64 2) (array 10 20)]
    (set! global-index 0)
    (set! (array-ref a global-index) (move-index))
    (test.assert-i64-eq (array-ref a 0) 7 "global index")
    (test.assert-i64-eq (array-ref a 1) 20 "global sibling")
    (test.assert-i64-eq global-index 1 "global index write"))
  (let
    [a : (Array (Array i64 1) 1) (array (array 10))]
    (set! trace 0)
    (set!
      (array-ref (array-ref a (mark 1)) (mark 2))
      (begin
        (mark 3)
        7))
    (test.assert-i64-eq trace 123 "nested place evaluated once")
    (test.assert-i64-eq (array-ref (array-ref a 0) 0) 7 "nested store"))
  (let
    [a : (Array i64 2) (array 10 20)]
    (set-through-slice (&mut a))
    (test.assert-i64-eq (array-ref a 0) 7 "slice original index")
    (test.assert-i64-eq (array-ref a 1) 20 "slice sibling"))
  (let
    [a : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    [index : i64 0]
    (set!
      (array-ref a index)
      (begin
        (set! index 1)
        (Pair 7 8)))
    (test.assert-i64-eq (array-ref a 0).a 7 "register group element")
    (test.assert-i64-eq (array-ref a 0).b 8 "register group second word")
    (test.assert-i64-eq (array-ref a 1).a 3 "register group sibling")
    (test.assert-i64-eq index 1 "group index write"))
  (let
    [a : (Array Wide 2) (array (Wide 1 2 3 4) (Wide 5 6 7 8))]
    [index : i64 0]
    (set!
      (array-ref a index)
      (begin
        (set! index 1)
        (Wide 9 10 11 12)))
    (test.assert-i64-eq (array-ref a 0).a 9 "direct aggregate store")
    (test.assert-i64-eq (array-ref a 0).d 12 "aggregate last word")
    (test.assert-i64-eq (array-ref a 1).a 5 "aggregate sibling")
    (test.assert-i64-eq index 1 "aggregate index write"))
  (let
    [a : (Array String 2) (array "old" "sibling")]
    [index : i64 0]
    (set!
      (array-ref a index)
      (begin
        (set! index 1)
        "new value"))
    (test.assert-i64-eq
      (string.string-length (& (array-ref a 0)))
      9
      "owned element")
    (test.assert-i64-eq
      (string.string-length (& (array-ref a 1)))
      7
      "owned sibling")
    (test.assert-i64-eq index 1 "owned index write"))
  (let
    [a : (Array unit 1) (array unit)]
    [side : i64 0]
    (set!
      (array-ref
        a
        (begin
          (+= side 1)
          0))
      (begin
        (+= side 10)
        unit))
    (test.assert-i64-eq side 11 "zero-sized effects"))
  (let
    [b : (Box i64) (box 10)]
    (set!
      (deref b)
      (begin
        (set! b (box 20))
        7))
    (test.assert-i64-eq (deref b) 20 "selected box address stays fixed"))
  42)