;; A view read through a shared reborrow of a `&mut` is behind the shared
;; reference (#9646).
(defstruct Holder
  (b (Box i64)))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Holder)]) : i64
  (let
    [s (& (deref r))]
    [b : (Box i64) s.b]
    (sink b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 42))]
    (take (&mut h))))