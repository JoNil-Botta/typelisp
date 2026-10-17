;; By-value memory-class operands must not observe writes made by later
;; operands of the same call (#8433, #7900). Each case names the storage a
;; later operand writes and pins the pre-write value; the lowering may omit a
;; snapshot only when it proves no later operand can change that storage.
(import stdlib.io)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defstruct Outer
  (inner Triple)
  (tag i64))

(define global-triple : Triple
  (Triple 1 2 3))
(define global-count : i64
  7)

(define (bump-count!) : i64
  (begin
    (set! global-count 700)
    0))

(define (first-a [t : Triple] [_n : i64]) : i64
  t.a)

(define (inner-a [t : Triple] [_n : i64] [_m : i64]) : i64
  t.a)

(define (bump-a! [t : (&mut t Triple)]) : i64
  (begin
    (set! t.a (+ t.a 100))
    0))

(define (bump-outer! [o : (&mut o Outer)]) : i64
  (begin
    (set! o.inner.a (+ o.inner.a 1000))
    0))

(define (bump-global!) : i64
  (begin
    (set! global-triple (Triple 70 80 90))
    0))

(defmacro (overwrite-a! [place : Expr] [value : Expr]) : Expr
  `(begin
    (set! ,place ,value)
    0))

;; A later operand that assigns a field of the same local.
(define (field-set-case) : i64
  (let
    [t : Triple (Triple 5 6 7)]
    (first-a
      t
      (begin
        (set! t.a 50)
        0))))

;; A later operand that passes an explicit mutable borrow.
(define (mut-borrow-case) : i64
  (let
    [t : Triple (Triple 9 6 7)]
    (first-a t (bump-a! (&mut t)))))

;; A dotted projection of an aggregate field, written through the root.
(define (projection-case) : i64
  (let
    [o : Outer (Outer (Triple 11 12 13) 1)]
    (inner-a o.inner 0 (bump-outer! (&mut o)))))

;; A dotted mutable borrow of the projected field itself.
(define (dotted-borrow-case) : i64
  (let
    [o : Outer (Outer (Triple 71 72 73) 1)]
    (inner-a o.inner 0 (bump-a! (&mut o.inner)))))

;; A macro-generated assignment still names the same local after expansion.
(define (macro-case) : i64
  (let
    [t : Triple (Triple 21 22 23)]
    (first-a t (overwrite-a! t.a 210))))

;; A global operand changed by a later call that never names it syntactically.
(define (global-case) : i64
  (begin
    (set! global-triple (Triple 31 32 33))
    (first-a global-triple (bump-global!))))

;; A raw address taken earlier aliases the local without naming it later.
(define (raw-address-case) : i64
  (let
    [t : Triple (Triple 41 42 43)]
    [p : (MutPtr Triple)
      (unsafe
        (ptr-addr-of t))]
    (first-a
      t
      (unsafe
        (begin
          (ptr-write! p (Triple 410 420 430))
          0)))))

;; A later impure operand that does not name the local cannot change it; the
;; result is the same whether or not a snapshot is made.
(define (unrelated-call-case) : i64
  (let
    [t : Triple (Triple 51 52 53)]
    [u : Triple (Triple 1 1 1)]
    (first-a t (bump-a! (&mut u)))))

;; A binary operator's left operand is also evaluated first.
(define (binary-local-case) : i64
  (let
    [x : i64 81]
    (+
      x
      (begin
        (set! x 810)
        0))))

(define (binary-global-case) : i64
  (begin
    (set! global-count 91)
    (+ global-count (bump-count!))))

;; A constructor's later operand writes an earlier aggregate operand.
(define (constructor-later-write-case) : i64
  (let
    [t : Triple (Triple 111 112 113)]
    [o : Outer
      (Outer
        t
        (begin
          (set! t.a 1110)
          0))]
    o.inner.a))

;; A raw view of a local, followed by an operand that writes that local.
(define (raw-view-later-write-case) : i64
  (let
    [t : Triple (Triple 121 122 123)]
    (first-a
      (unsafe
        (ptr-read (ptr-addr-of t)))
      (begin
        (set! t.a 1210)
        0))))

;; Effect-free later operands.
(define (reads-case) : i64
  (let
    [t : Triple (Triple 61 62 63)]
    (inner-a t (+ t.b 1) (* t.c 2))))

(define (main) : i64
  (let
    [results : i64
      (+
        (if (= (field-set-case) 5)
          1
          0)
        (if (= (mut-borrow-case) 9)
          2
          0)
        (if (= (projection-case) 11)
          4
          0)
        (if (= (macro-case) 21)
          8
          0)
        (if (= (global-case) 31)
          16
          0)
        (if (= (raw-address-case) 41)
          32
          0)
        (if (= (unrelated-call-case) 51)
          64
          0)
        (if (= (reads-case) 61)
          128
          0)
        (if (= (dotted-borrow-case) 71)
          256
          0)
        (if (= (binary-local-case) 81)
          512
          0)
        (if (= (binary-global-case) 91)
          1024
          0)
        (if (= (constructor-later-write-case) 111)
          2048
          0)
        (if (= (raw-view-later-write-case) 121)
          4096
          0))]
    (begin
      (io.print-format "{}\n" results)
      (if (= results 8191)
        42
        results))))