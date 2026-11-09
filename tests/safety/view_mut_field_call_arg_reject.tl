;; Moving a view of a field read through `&mut` names the mutable reference,
;; not a shared one (#9646).
(defstruct Holder
  (b (Box i64)))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Holder)]) : i64
  (let
    [b : (Box i64) r.b]
    (sink b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 42))]
    (take (&mut h))))