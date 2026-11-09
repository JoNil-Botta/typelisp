;; A view read through a `&mut` held in a struct behind `&mut` names the
;; mutable reference (#9646).
(defstruct Holder
  (b (Box i64)))

(defstruct Link
  (:lifetimes p)
  (h (&mut p Holder)))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r (Link p))]) : i64
  (let
    [b : (Box i64) r.h.b]
    (sink b)))

(define (main) : i64
  0)