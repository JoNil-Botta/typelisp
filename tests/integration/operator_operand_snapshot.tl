;; Every evaluated operand retains its value, and the later write still runs.
(import stdlib.test)

(define counter : i64
  0)

(define (bump) : i64
  (set! counter 99)
  5)

(define (write-99 [p : (MutPtr i64)]) : i64
  (unsafe
    (ptr-write! p 99))
  2)

(define (set-99 [p : (&mut p i64)]) : i64
  (set! (deref p) 99)
  2)

(defstruct Pair
  (a i64)
  (b i64))

(define (interactions) : unit
  (let
    [x : i64 1]
    [y : i64 1]
    [pair : Pair (Pair 2 3)]
    [result : i64
      (+
        x
        (begin
          (set! x 2)
          x)
        (begin
          (set! x 99)
          3))]
    (test.assert-i64-eq result 6 "variadic operands")
    (test.assert-i64-eq x 99 "both writes")
    (test.assert-i64-eq
      (+
        (if true
          y
          0)
        (begin
          (set! y 99)
          2))
      3
      "branch result")
    (test.assert-i64-eq y 99 "branch later write")
    (test.assert-true
      (=
        pair
        (begin
          (set! pair (Pair 8 9))
          (Pair 2 3)))
      "register group equality")
    (test.assert-i64-eq pair.a 8 "group write")
    (test.assert-i64-eq pair.b 9 "group sibling"))
  (let
    [x : i64 1]
    [y : i64 1]
    [saved : i64 y]
    (test.assert-i64-eq
      (+
        x
        (begin
          (set! x 99)
          2))
      (+
        saved
        (begin
          (set! y 99)
          2))
      "explicit snapshot oracle")
    (test.assert-i64-eq x 99 "oracle first write")
    (test.assert-i64-eq y 99 "oracle second write"))
  (set! counter 1)
  (test.assert-i64-eq (+ counter (bump)) 6 "global callee")
  (test.assert-i64-eq counter 99 "global write")
  (set! counter 1)
  (test.assert-true (< counter (bump)) "global comparison")
  (test.assert-i64-eq counter 99 "global comparison write")
  (let
    [x : i64 1]
    (test.assert-i64-eq (+ x (set-99 (&mut x))) 3 "later mutable borrow")
    (test.assert-i64-eq x 99 "borrow write"))
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (test.assert-i64-eq (+ x (write-99 p)) 3 "earlier raw address")
    (test.assert-i64-eq x 99 "raw write"))
  (let
    [x : i64 1]
    [side : i64 0]
    (test.assert-true
      (not
        (and
          false
          (begin
            (set! side 1)
            true)))
      "and short circuit")
    (test.assert-true
      (or
        true
        (begin
          (set! side 2)
          false))
      "or short circuit")
    (test.assert-i64-eq side 0 "untaken writes")
    (test.assert-i64-eq
      (+
        x
        (if true
          (begin
            (set! x 99)
            2)
          0))
      3
      "nested branch")
    (test.assert-i64-eq x 99 "nested write")))

(define (check-arithmetic
  [op : i64]
  [start : i64]
  [rhs : i64]
  [updated : i64]
  [expected : i64]) : unit
  (let
    [x : i64 start]
    [result : i64
      (match op
        [0
          (+
            x
            (begin
              (set! x updated)
              rhs))]
        [1
          (-
            x
            (begin
              (set! x updated)
              rhs))]
        [2
          (*
            x
            (begin
              (set! x updated)
              rhs))]
        [3
          (/
            x
            (begin
              (set! x updated)
              rhs))]
        [4
          (%
            x
            (begin
              (set! x updated)
              rhs))]
        [5
          (bit-and
            x
            (begin
              (set! x updated)
              rhs))]
        [6
          (bit-or
            x
            (begin
              (set! x updated)
              rhs))]
        [7
          (bit-xor
            x
            (begin
              (set! x updated)
              rhs))]
        [8
          (shl
            x
            (begin
              (set! x updated)
              rhs))]
        [9
          (shr
            x
            (begin
              (set! x updated)
              rhs))]
        [_ 0])]
    (test.assert-i64-eq result expected "arithmetic operand")
    (test.assert-i64-eq x updated "arithmetic later write")))

(define (check-comparison
  [op : i64]
  [start : i64]
  [rhs : i64]
  [updated : i64]
  [expected : bool]) : unit
  (let
    [x : i64 start]
    [result : bool
      (match op
        [0
          (=
            x
            (begin
              (set! x updated)
              rhs))]
        [1
          (!=
            x
            (begin
              (set! x updated)
              rhs))]
        [2
          (<
            x
            (begin
              (set! x updated)
              rhs))]
        [3
          (<=
            x
            (begin
              (set! x updated)
              rhs))]
        [4
          (>
            x
            (begin
              (set! x updated)
              rhs))]
        [5
          (>=
            x
            (begin
              (set! x updated)
              rhs))]
        [_ false])]
    (test.assert-true (= result expected) "comparison operand")
    (test.assert-i64-eq x updated "comparison later write")))

(define (main) : i64
  (check-arithmetic 0 7 3 99 10)
  (check-arithmetic 1 7 3 99 4)
  (check-arithmetic 2 7 3 99 21)
  (check-arithmetic 3 7 3 99 2)
  (check-arithmetic 4 7 3 99 1)
  (check-arithmetic 5 7 3 99 3)
  (check-arithmetic 6 4 3 99 7)
  (check-arithmetic 7 7 3 99 4)
  (check-arithmetic 8 3 2 99 12)
  (check-arithmetic 9 12 2 99 3)
  (check-comparison 0 7 7 99 true)
  (check-comparison 1 7 99 99 true)
  (check-comparison 2 7 8 99 true)
  (check-comparison 3 7 7 99 true)
  (check-comparison 4 7 6 0 true)
  (check-comparison 5 7 7 0 true)
  (let
    [x : bool true]
    (test.assert-true
      (and
        x
        (begin
          (set! x false)
          true))
      "and operand")
    (test.assert-true (not x) "and later write"))
  (let
    [x : bool false]
    (test.assert-true
      (not
        (or
          x
          (begin
            (set! x true)
            false)))
      "or operand")
    (test.assert-true x "or later write"))
  (let
    [x : i8 (cast 127 : i8)]
    (test.assert-true
      (=
        (+
          x
          (begin
            (set! x (cast 0 : i8))
            (cast 1 : i8)))
        (cast -128 : i8))
      "wrapping narrow value")
    (test.assert-true (= x (cast 0 : i8)) "narrow later write"))
  (let
    [x : u8 (cast 128 : u8)]
    (test.assert-true
      (=
        (shr
          x
          (begin
            (set! x (cast 0 : u8))
            (cast 7 : u8)))
        (cast 1 : u8))
      "unsigned high shift")
    (test.assert-true (= x (cast 0 : u8)) "unsigned later write"))
  (let
    [x : u64 (cast 1 : u64)]
    (test.assert-true
      (=
        (shl
          x
          (begin
            (set! x (cast 0 : u64))
            (cast 63 : u64)))
        (cast 9223372036854775808 : u64))
      "widest shift")
    (test.assert-true (= x (cast 0 : u64)) "widest later write"))
  (let
    [x : f64 1.5]
    (test.assert-true
      (=
        (+
          x
          (begin
            (set! x 99.0)
            2.0))
        3.5)
      "f64 operand")
    (test.assert-true (= x 99.0) "f64 later write"))
  (let
    [x : f32 (cast 1.5 : f32)]
    (test.assert-true
      (=
        (*
          x
          (begin
            (set! x (cast 99.0 : f32))
            (cast 2.0 : f32)))
        (cast 3.0 : f32))
      "f32 operand")
    (test.assert-true (= x (cast 99.0 : f32)) "f32 later write")
    (set! x (cast 1.5 : f32))
    (test.assert-true
      (<
        x
        (begin
          (set! x (cast 99.0 : f32))
          (cast 2.0 : f32)))
      "f32 comparison")
    (test.assert-true (= x (cast 99.0 : f32)) "f32 comparison write"))
  (interactions)
  42)