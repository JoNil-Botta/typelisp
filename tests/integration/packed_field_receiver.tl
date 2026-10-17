(import stdlib.test)

(defstruct Small
  (a i32)
  (b i32))

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64))

(defstruct Nested
  (inner Small)
  (tail i64))

(define calls : i64
  0)

(define (write-sibling [p : (&mut p Pair)]) : i64
  (+= calls 1)
  (set! p.b 20)
  7)

(define (write-whole [p : (&mut p Pair)]) : i64
  (set! (deref p) (Pair 7 8))
  5)

(define (small-sibling) : bool
  (let
    [p : Small (Small 1 2)]
    (set!
      p.a
      (begin
        (set! p.b 20)
        7))
    (and (= p.a 7) (= p.b 20))))

(define (pair-sibling) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (begin
        (set! p.b 20)
        7))
    (and (= p.a 7) (= p.b 20))))

(define (nested-sibling) : bool
  (let
    [p : Nested (Nested (Small 1 2) 30)]
    (set!
      p.inner.a
      (begin
        (set! p.inner.b 20)
        7))
    (and (= p.inner.a 7) (= p.inner.b 20) (= p.tail 30))))

(define (borrowed-sibling) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set! calls 0)
    (set! p.a (write-sibling (&mut p)))
    (and (= p.a 7) (= p.b 20) (= calls 1))))

;; A whole write through a reference mutates the selected object; a whole
;; local assignment below replaces the binding with another value.
(define (borrowed-whole) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set! p.a (write-whole (&mut p)))
    (and (= p.a 5) (= p.b 8))))

(define (small-rebind [replace : bool]) : bool
  (let
    [p : Small (Small 1 2)]
    [q : Small (Small 7 8)]
    (set!
      p.a
      (begin
        (when replace (set! p q))
        5))
    (if replace
      (and (= p.a 7) (= p.b 8))
      (and (= p.a 5) (= p.b 2)))))

(define (pair-rebind [replace : bool]) : bool
  (let
    [p : Pair (Pair 1 2)]
    [q : Pair (Pair 7 8)]
    (set!
      p.a
      (begin
        (when replace (set! p q))
        5))
    (if replace
      (and (= p.a 7) (= p.b 8))
      (and (= p.a 5) (= p.b 2)))))

(define (wide-rebind) : bool
  (let
    [p : Wide (Wide 1 2 3)]
    [q : Wide (Wide 7 8 9)]
    (set!
      p.a
      (begin
        (set! p q)
        5))
    (and (= p.a 7) (= p.b 8) (= p.c 9))))

(define (equal-rebind) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (begin
        (set! p (Pair 1 2))
        5))
    (and (= p.a 1) (= p.b 2))))

(define (nested-rebind) : bool
  (let
    [p : Nested (Nested (Small 1 2) 30)]
    (set!
      p.inner.a
      (begin
        (set! p (Nested (Small 7 8) 90))
        5))
    (and (= p.inner.a 7) (= p.inner.b 8) (= p.tail 90))))

(define (nested-stores-rebind) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (begin
        (set!
          p.b
          (begin
            (set! p (Pair 7 8))
            4))
        5))
    (and (= p.a 7) (= p.b 8))))

(define (loop-rebind) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (let
        [i : i64 0]
        (while (< i 3)
          (set! p (Pair (+ 7 i) 8))
          (+= i 1))
        5))
    (and (= p.a 9) (= p.b 8))))

(define (shadow-rebind) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (let
        [p : Pair (Pair 10 20)]
        (set! p (Pair 7 8))
        (- p.a 2)))
    (and (= p.a 5) (= p.b 2))))

(defstruct EmptyField
  (tag unit)
  (value i64))

(define (zero-sized-field) : bool
  (let
    [p : EmptyField (EmptyField unit 1)]
    (set!
      p.tag
      (begin
        (set! p.value 21)
        unit))
    (and
      (= p.value 21)
      (begin
        (set!
          p.tag
          (begin
            (set! p (EmptyField unit 42))
            unit))
        (= p.value 42)))))

(define (tuple-control) : bool
  (let
    [p : (Tuple i64 i64) (tuple 1 2)]
    (set!
      (tuple-ref p 0)
      (begin
        (set! (tuple-ref p 1) 20)
        7))
    (and
      (= (tuple-ref p 0) 7)
      (= (tuple-ref p 1) 20)
      (begin
        (set!
          (tuple-ref p 0)
          (begin
            (set! p (tuple 7 8))
            5))
        (and (= (tuple-ref p 0) 7) (= (tuple-ref p 1) 8))))))

;; Compare both packed representations with a scalar state-transition oracle.
;; Equal-content replacement must still replace the selected object.
(define (transition-property [x : i64] [y : i64] [action : i64]) : bool
  (let
    [small : Small (Small (cast x : i32) (cast y : i32))]
    [pair : Pair (Pair x y)]
    [expected-a : i64
      (if (= action 0)
        7
        (if (= action 1)
          (+ x 2)
          x))]
    [expected-b : i64
      (if (= action 0)
        (+ y 1)
        (if (= action 1)
          (+ y 3)
          y))]
    (set!
      small.a
      (begin
        (if (= action 0)
          (set! small.b (cast (+ y 1) : i32))
          (if (= action 1)
            (set! small (Small (cast (+ x 2) : i32) (cast (+ y 3) : i32)))
            (set! small (Small (cast x : i32) (cast y : i32)))))
        7))
    (set!
      pair.a
      (begin
        (if (= action 0)
          (set! pair.b (+ y 1))
          (if (= action 1)
            (set! pair (Pair (+ x 2) (+ y 3)))
            (set! pair (Pair x y))))
        7))
    (and
      (= (cast small.a : i64) expected-a)
      (= (cast small.b : i64) expected-b)
      (= pair.a expected-a)
      (= pair.b expected-b))))

(define (main) : i64
  (test.assert-true (small-sibling) "one-word sibling update")
  (test.assert-true (pair-sibling) "two-word sibling update")
  (test.assert-true (nested-sibling) "nested sibling update")
  (test.assert-true (borrowed-sibling) "one RHS call through mutable reference")
  (test.assert-true (borrowed-whole) "whole referent write keeps object")
  (test.assert-true (small-rebind true) "one-word replacement keeps new value")
  (test.assert-true (small-rebind false) "one-word untaken replacement")
  (test.assert-true (pair-rebind true) "two-word replacement keeps new value")
  (test.assert-true (pair-rebind false) "two-word untaken replacement")
  (test.assert-true (wide-rebind) "memory-class replacement control")
  (test.assert-true (equal-rebind) "replacement with equal contents")
  (test.assert-true (nested-rebind) "nested field after root replacement")
  (test.assert-true (nested-stores-rebind) "nested retained receivers")
  (test.assert-true (loop-rebind) "repeated replacement in RHS loop")
  (test.assert-true (shadow-rebind) "shadowed binding is independent")
  (test.assert-true (zero-sized-field) "zero-sized field keeps RHS effects")
  (test.assert-true (tuple-control) "tuple receiver control")
  (let
    [x : i64 -16]
    (while (<= x 16)
      (let
        [action : i64 0]
        (while (< action 3)
          (test.assert-true
            (transition-property x (- 31 x) action)
            "packed receiver scalar oracle")
          (+= action 1)))
      (+= x 1)))
  42)