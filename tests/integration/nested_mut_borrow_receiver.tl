(defstruct Inner
  (x i64))

(defstruct Outer
  (inner Inner)
  (tail i64))

(define (change! [p : (&mut p i64)]) : unit
  (set! (deref p) 5))

(define (nested! [p : (&mut p Outer)]) : unit
  (change! (&mut p.inner.x)))

(define (main) : i64
  (let
    [s : Outer (Outer (Inner 1) 20)]
    (nested! (&mut s))
    s.inner.x))