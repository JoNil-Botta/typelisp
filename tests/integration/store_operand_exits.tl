;; A store evaluates its place before its RHS and commits only on fallthrough.
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(define trace : i64
  0)
(define global-number : i64
  7)
(define global-pair : Pair
  (Pair 1 2))

(define (mark [digit : i64]) : i64
  (set! trace (+ (* trace 10) digit))
  0)

(define (returning-store [mode : i64]) : i64
  (match mode
    ;; scalar
    [0
      (let
        [_n : i64 0]
        (set! _n (return 42))
        1)]
    ;; whole
    [1
      (let
        [_p : Pair (Pair 1 2)]
        (set! _p (return 42))
        1)]
    ;; field
    [2
      (let
        [_p : Pair (Pair 1 2)]
        (set!
          _p.a
          (begin
            (set! _p (Pair 7 8))
            (return 42)))
        1)]
    ;; tuple
    [3
      (let
        [p : (Tuple i64 i64) (tuple 1 2)]
        (set! (tuple-ref p 0) (return 42))
        1)]
    ;; fixed
    [4
      (let
        [p : (Array i64 1) (array 1)]
        (set! (array-ref p 0) (return 42))
        1)]
    ;; computed
    [5
      (let
        [p : (Array i64 1) (array 1)]
        (set!
          (array-ref p (mark 4))
          (begin
            (mark 2)
            (return trace)))
        1)]
    ;; dynamic
    [6
      (let
        [p : (__tl_dyn-array i64) (__tl_make-array i64 1)]
        (set! (array-ref p 0) (return 42))
        1)]
    ;; box
    [7
      (let
        [p : (Box i64) (box 1)]
        (set! (deref p) (return 42))
        1)]
    ;; mutref
    [8
      (let
        [n : i64 1]
        [answer : i64 (reference-store (&mut n))]
        (test.assert-i64-eq n 1 "reference store not reached")
        answer)]
    ;; global
    [9
      (begin
        (set! global-number (return 42))
        1)]
    ;; global-field
    [10
      (begin
        (set!
          global-pair.a
          (begin
            (set! global-pair.b 20)
            (return 42)))
        1)]
    ;; replace
    [11
      (let
        [p : Pair (Pair 1 2)]
        (replace! p.a (return 42))
        1)]
    ;; replace-array
    [12
      (let
        [p : (Array i64 1) (array 1)]
        (replace! (array-ref p 0) (return 42))
        1)]
    ;; ptr-write
    [13
      (let
        [n : i64 1]
        [p : (MutPtr i64)
          (unsafe
            (ptr-addr-of n))]
        (unsafe
          (ptr-write! p (return 42)))
        1)]
    ;; raw-field
    [14
      (let
        [n : Pair (Pair 1 2)]
        [p : (MutPtr Pair)
          (unsafe
            (ptr-addr-of n))]
        (unsafe
          (set! (deref p).a (return 42)))
        1)]
    ;; selected-receiver
    [15
      (let
        [a : (Array i64 1) (array 1)]
        [b : (Array i64 1) (array 2)]
        (set!
          (array-ref
            (if (= (mark 4) 0)
              a
              b)
            0)
          (begin
            (mark 2)
            (return trace)))
        1)]
    ;; move-element
    [16
      (let
        [a : (Array (Box i64) 1) (array (box 1))]
        (set! (array-ref a 0) (return 42))
        1)]
    [_ 0]))

(define (reference-store [p : (&mut p i64)]) : i64
  (set! (deref p) (return 42))
  1)

(define (slice-store [a : (&mut a (Slice i64))]) : i64
  (set!
    (array-ref a (mark 4))
    (begin
      (mark 2)
      (return trace)))
  1)

(define (conditional-store [leave : bool]) : i64
  (let
    [p : Pair (Pair 1 2)]
    (set!
      p.a
      (if leave
        (return 42)
        40))
    (+ p.a p.b)))

(define (loop-stores) : i64
  (let
    [p : Pair (Pair 1 2)]
    [a : (Array i64 1) (array 3)]
    [i : i64 0]
    (while (< i 3)
      (+= i 1)
      (set!
        p.a
        (begin
          (+= p.b 10)
          (continue)))
      (set! p.b 0))
    (while true
      (set!
        (array-ref a 0)
        (begin
          (+= p.b 6)
          (break)))
      (set! p.b 0))
    (test.assert-i64-eq (array-length a) 1 "fixed-array length survives exits")
    (+ p.a (+ p.b (array-ref a 0)))))

(define (scalar-continue) : i64
  (let
    [n : i64 2]
    [i : i64 0]
    (while (< i 3)
      (+= i 1)
      (set!
        n
        (begin
          (+= n 10)
          (continue)))
      (set! n 0))
    (+ n 1)))

(define (main) : i64
  (test.assert-i64-eq
    (scalar-continue)
    33
    "scalar continue preserves prior effects")
  (let
    [mode : i64 0]
    (while (< mode 17)
      (set! trace 0)
      (test.assert-i64-eq
        (returning-store mode)
        42
        "return skips the store and tail")
      (+= mode 1)))
  (test.assert-i64-eq global-number 7 "global scalar store not reached")
  (test.assert-i64-eq global-pair.a 1 "global field store not reached")
  (test.assert-i64-eq global-pair.b 20 "RHS effects run before returning")
  (set! trace 0)
  (let
    [a : (Array i64 1) (array 9)]
    (test.assert-i64-eq (slice-store (&mut a)) 42 "slice index and RHS order")
    (test.assert-i64-eq (array-ref a 0) 9 "slice store not reached"))
  (test.assert-i64-eq (conditional-store true) 42 "conditional return")
  (test.assert-i64-eq
    (conditional-store false)
    42
    "conditional fallthrough stores")
  (test.assert-i64-eq
    (loop-stores)
    42
    "break and continue skip writes and tails")
  42)