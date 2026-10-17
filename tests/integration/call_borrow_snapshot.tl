;; Borrow addresses keep their identity across argument evaluation, while
;; a by-value aggregate retains its pre-call value across a mutable alias.
(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define (read-two [a : (& a Triple)] [b : (&mut b Triple)]) : i64
  (+ a.a b.b))

(define (write-two [a : (&mut a Triple)] [b : (&mut b Triple)]) : i64
  (set! a.a (+ a.a 1))
  (+ a.a b.b))

(define (copy-and-write [a : Triple] [b : (&mut b Triple)]) : i64
  (set! b.a 99)
  a.a)

(define (plain-shared [a : (& a Triple)] [b : (&mut b Triple)]) : i64
  (read-two a (&mut b)))

(define (plain-mut [a : (&mut a Triple)] [b : (&mut b Triple)]) : i64
  (write-two (&mut a) (&mut b)))

(define (effect [a : (& a Triple)] [b : (&mut b Triple)]) : i64
  (read-two
    a
    (begin
      (set! b.b 12)
      (&mut b))))

(define (value-copy) : i64
  (let
    [a : Triple (Triple 7 8 9)]
    (copy-and-write a (&mut a))))

(define (main) : i64
  (let
    [a : Triple (Triple 10 20 30)]
    [b : Triple (Triple 40 2 60)]
    (if (and
      (= (plain-shared (& a) (&mut b)) 12)
      (= (plain-mut (&mut a) (&mut b)) 13)
      (= (effect (& a) (&mut b)) 23)
      (= (value-copy) 7))
      42
      1)))