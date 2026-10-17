;; A constructor or call argument exit cancels the enclosing store and its tail.
(import stdlib.test)

(defstruct Wide
  (a i64)
  (b i64)
  (c i64))

(defstruct Holder
  (wide Wide))

(defstruct Zero
  (z unit))

(defenum Choice
  (Full Wide)
  (Blank))

(define trace : i64
  0)

(define (mark [digit : i64]) : i64
  (set! trace (+ (* trace 10) digit))
  digit)

(define (sum [a : i64] [b : i64]) : i64
  (+ a b))

(define (use-ref [p : (&mut p i64)] [v : i64]) : i64
  (+ (deref p) v))

(define (run-case [mode : i64]) : i64
  (match mode
    [0
      (let
        [_p : Holder (Holder (Wide 1 2 3))]
        (set! _p.wide (Wide (mark 1) (return 42) (mark 9)))
        1)]
    [1
      (let
        [_p : Choice (Full (Wide 1 2 3))]
        (set! _p (Full (Wide (mark 1) (return 42) (mark 9))))
        1)]
    [2
      (let
        [_p : (Array i64 3) (array 1 2 3)]
        (set! _p (array (mark 1) (return 42) (mark 9)))
        1)]
    [3
      (let
        [_n : i64 1]
        (set! _n (sum (mark 1) (return 42)))
        1)]
    [4
      (let
        [_p : (Array i64 1) (array 7)]
        (replace!
          (array-ref
            _p
            (ann
              (begin
                (mark 1)
                (return 42))
              : i64))
          (mark 9))
        1)]
    [5
      (begin
        (set!
          (array-ref
            (ann
              (begin
                (mark 1)
                (return 42))
              : (Array i64 1))
            (mark 9))
          (mark 9))
        1)]
    [6
      (let
        [_n : i64 1]
        [m : i64 2]
        (set!
          _n
          (use-ref
            (&mut m)
            (begin
              (mark 1)
              (return 42))))
        1)]
    [7
      (let
        [_p : (Array Wide 1) (array (Wide 1 2 3))]
        (set! (array-ref _p 99) (Wide (mark 1) (return 42) (mark 9)))
        1)]
    [8
      (let
        [_p : Zero (Zero unit)]
        (set!
          _p.z
          (begin
            (mark 1)
            (return 42)))
        1)]
    [9
      (let
        [_p : Zero (Zero unit)]
        (set!
          _p
          (begin
            (mark 1)
            (return 42)))
        1)]
    [10
      (let
        [_p : (__tl_dyn-array Wide) (__tl_make-array Wide 1)]
        (set! (array-ref _p 99) (Wide (mark 1) (return 42) (mark 9)))
        1)]
    [11
      (let
        [_n : i64 1]
        [f : (-> i64 i64 i64) sum]
        (set! _n (f (mark 1) (return 42)))
        1)]
    [_ 0]))

(define (conditional [leave : bool]) : i64
  (let
    [p : Holder (Holder (Wide 1 2 3))]
    (set!
      p.wide
      (Wide
        1
        (if leave
          (return 42)
          20)
        21))
    (+ p.wide.a (+ p.wide.b p.wide.c))))

(define (main) : i64
  (let
    [mode : i64 0]
    (while (< mode 12)
      (set! trace 0)
      (test.assert-i64-eq (run-case mode) 42 "operand exit skips store")
      (test.assert-i64-eq trace 1 "only operands before the exit run")
      (+= mode 1)))
  (test.assert-i64-eq (conditional true) 42 "constructor exit")
  (test.assert-i64-eq
    (conditional false)
    42
    "constructor commits on fallthrough")
  42)