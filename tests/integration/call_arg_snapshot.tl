;; #8433: call arguments are evaluated left to right (SPEC section 5.3), so an
;; argument passes the value it had when it was evaluated, even when a later
;; argument assigns the variable it read. Each check compares the call with a
;; fixed expectation or an explicit snapshot oracle, and checks that the later
;; assignment still happened. Exits 42, or the number of the first failed check.
(defstruct Pair
  (a i64)
  (b i64))

(define (first [a : i64] [_b : i64]) : i64
  a)

(define (second [_a : i64] [b : i64]) : i64
  b)

(define (digits [a : i64] [b : i64] [c : i64]) : i64
  (+ (+ (* a 10000) (* b 100)) c))

(define (first-i32 [a : i32] [_b : i64]) : i32
  a)

(define (first-u8 [a : u8] [_b : i64]) : u8
  a)

(define (first-bool [a : bool] [_b : i64]) : bool
  a)

(define (first-f64 [a : f64] [_b : i64]) : f64
  a)

(define (first-f32 [a : f32] [_b : i64]) : f32
  a)

(define (first-char [a : char] [_b : i64]) : char
  a)

(define (first-ptr [p : (MutPtr i64)] [_b : i64]) : (MutPtr i64)
  p)

(define (pair-a [p : Pair] [_b : i64]) : i64
  p.a)

(define (first-unit [a : i64] [_u : unit]) : i64
  a)

;; Eight arguments, so the last two are passed on the stack.
(define (seventh
  [_a : i64]
  [_b : i64]
  [_c : i64]
  [_d : i64]
  [_e : i64]
  [_f : i64]
  [g : i64]
  [_h : i64]) : i64
  g)

(define (set-99 [p : (&mut p i64)]) : i64
  (set! (deref p) 99)
  0)

(define (write-99 [p : (MutPtr i64)]) : i64
  (unsafe
    (ptr-write! p 99))
  0)

(define (direct) : bool
  (let
    [x : i64 1]
    (and
      (=
        (first
          x
          (begin
            (set! x 99)
            0))
        1)
      (= x 99))))

(define (direct-tail [x : i64]) : i64
  (first
    x
    (begin
      (set! x 99)
      0)))

;; The value the call passes, against copying it by hand first.
(define (oracle) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    [saved : i64 y]
    (=
      (first
        x
        (begin
          (set! x 99)
          0))
      (first
        saved
        (begin
          (set! y 99)
          0)))))

(define (widths) : bool
  (let
    [i : i32 (cast 1 : i32)]
    [u : u8 (cast 1 : u8)]
    [b : bool true]
    [d : f64 1.5]
    [f : f32 (cast 1.5 : f32)]
    [c : char 'a']
    (and
      (=
        (first-i32
          i
          (begin
            (set! i (cast 99 : i32))
            0))
        (cast 1 : i32))
      (=
        (first-u8
          u
          (begin
            (set! u (cast 99 : u8))
            0))
        (cast 1 : u8))
      (first-bool
        b
        (begin
          (set! b false)
          0))
      (=
        (first-f64
          d
          (begin
            (set! d 99.5)
            0))
        1.5)
      (=
        (first-f32
          f
          (begin
            (set! f (cast 99.5 : f32))
            0))
        (cast 1.5 : f32))
      (=
        (first-char
          c
          (begin
            (set! c 'z')
            0))
        'a')
      (= i (cast 99 : i32))
      (= u (cast 99 : u8))
      (not b)
      (= d 99.5)
      (= f (cast 99.5 : f32))
      (= c 'z'))))

;; Raw pointer values are compared, never dereferenced.
(define (pointer) : bool
  (let
    [one : i64 1]
    [two : i64 2]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of one))]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of two))]
    [saved : (MutPtr i64) p]
    [passed : (MutPtr i64)
      (first-ptr
        p
        (begin
          (set! p q)
          0))]
    (unsafe
      (and (= (ptr->int passed) (ptr->int saved)) (= (ptr->int p) (ptr->int q))))))

;; A parameter read twice, a parameter the callee ignores, and the read in the
;; second position.
(define (parameters) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    [z : i64 1]
    (and
      (=
        (digits
          x
          x
          (begin
            (set! x 2)
            0))
        10100)
      (=
        (second
          (begin
            (set! y 2)
            0)
          y)
        2)
      (=
        (second
          z
          (begin
            (set! z 2)
            z))
        2)
      (= x 2)
      (= y 2)
      (= z 2))))

;; The first read's later arguments write only another variable, which must
;; not stop the second read from being checked.
(define (second-read) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    (and
      (=
        (digits
          x
          y
          (begin
            (set! y 2)
            0))
        10100)
      (= y 2))))

;; Assignments nested in operator operands count too.
(define (in-operands) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    (and
      (=
        (first
          x
          (+
            0
            (begin
              (set! x 99)
              0)))
        1)
      (=
        (first
          y
          (neg
            (begin
              (set! y 99)
              0)))
        1)
      (= x 99)
      (= y 99))))

(define (two-assignments) : bool
  (let
    [x : i64 1]
    (and
      (=
        (digits
          x
          (begin
            (set! x 2)
            x)
          (begin
            (set! x 3)
            x))
        10203)
      (= x 3))))

(define (branches [take : bool]) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    (and
      (=
        (first
          x
          (if take
            (begin
              (set! x 99)
              0)
            0))
        1)
      (=
        (first
          (if take
            y
            5)
          (begin
            (set! y 99)
            0))
        1)
      (= x 99)
      (= y 99))))

(define (nested) : bool
  (let
    [x : i64 1]
    (and
      (=
        (digits
          x
          (first
            x
            (begin
              (set! x 2)
              0))
          (begin
            (set! x 3)
            0))
        10100)
      (= x 3))))

;; A block or `let` result is still the variable's storage, so the one-form
;; `begin` and the `unsafe` wrapper are deliberate.
(define (blocks) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    [z : i64 1]
    (and
      (=
        (first
          ;; lint-allow: single-begin
          (begin
            x)
          (begin
            (set! x 99)
            0))
        1)
      (=
        (first
          (let
            [_unused : i64 2]
            y)
          (begin
            (set! y 99)
            0))
        1)
      (=
        (first
          ;; lint-allow: unused-unsafe
          (unsafe
            z)
          (begin
            (set! z 99)
            0))
        1))))

(define (mutable-borrow) : bool
  (let
    [x : i64 1]
    (and (= (first x (set-99 (&mut x))) 1) (= x 99))))

(define (places) : bool
  (let
    [pair : Pair (Pair 1 2)]
    [whole : Pair (Pair 1 2)]
    [items : (Array i64 2) (array 1 2)]
    (and
      (=
        (first
          pair.a
          (begin
            (set! pair.a 99)
            0))
        1)
      (=
        (pair-a
          whole
          (begin
            (set! whole.a 99)
            0))
        1)
      (=
        (first
          (array-ref items 0)
          (begin
            (set! (array-ref items 0) 99)
            0))
        1)
      (= pair.a 99)
      (= whole.a 99)
      (= (array-ref items 0) 99))))

;; A raw pointer taken earlier lets a callee write a local without naming it
;; in the argument. The passed value and the final value are combined before
;; one comparison: a branch on the copy would hit #8672 at opt 2.
(define (address-taken) : bool
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (= (+ (* (first x (write-99 p)) 1000) x) 1099)))

(define (indirect) : bool
  (let
    [x : i64 1]
    [y : i64 1]
    [base : i64 0]
    [f : (-> i64 i64 i64) first]
    [g : (-> i64 i64 i64)
      (lambda ([a : i64] [_b : i64]) : i64
        (+ a base))]
    (and
      (=
        (f
          x
          (begin
            (set! x 99)
            0))
        1)
      (=
        (g
          y
          (begin
            (set! y 99)
            0))
        1)
      (= x 99)
      (= y 99))))

(define (stack-arguments) : bool
  (let
    [x : i64 1]
    (and
      (=
        (seventh
          0
          0
          0
          0
          0
          0
          x
          (begin
            (set! x 99)
            0))
        1)
      (= x 99))))

;; A unit argument has no value to pass but still runs its assignment.
(define (unit-argument) : bool
  (let
    [x : i64 1]
    (and (= (first-unit x (set! x 99)) 1) (= x 99))))

(define (in-loop) : bool
  (let
    [x : i64 0]
    [sum : i64 0]
    [i : i64 0]
    (while (< i 4)
      (set!
        sum
        (+
          sum
          (first
            x
            (begin
              (set! x (+ x 10))
              0))))
      (set! i (+ i 1)))
    (and (= sum 60) (= x 40))))

(define (main) : i64
  (cond
    [(not (direct)) 1]
    [(not (= (direct-tail 1) 1)) 2]
    [(not (oracle)) 3]
    [(not (widths)) 4]
    [(not (pointer)) 5]
    [(not (parameters)) 6]
    [(not (two-assignments)) 7]
    [(not (branches true)) 8]
    [(not (nested)) 9]
    [(not (blocks)) 10]
    [(not (mutable-borrow)) 11]
    [(not (places)) 12]
    [(not (address-taken)) 13]
    [(not (indirect)) 14]
    [(not (stack-arguments)) 15]
    [(not (unit-argument)) 16]
    [(not (in-loop)) 17]
    [(not (second-read)) 18]
    [(not (in-operands)) 19]
    [else 42]))