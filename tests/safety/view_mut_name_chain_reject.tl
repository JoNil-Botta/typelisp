;; A view bound from a view of a `&mut` field is still read through the
;; mutable reference (#9646).
(defstruct Holder
  (b (Box i64)))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Holder)]) : i64
  (let
    [b : (Box i64) r.b]
    [c : (Box i64) b]
    (sink c)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 42))]
    (take (&mut h))))