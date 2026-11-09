;; A binder of a match on a field read through `&mut` names the mutable
;; reference (#9646).
(defenum MaybeBox
  (Some (Box i64))
  (None))

(defstruct Holder
  (o MaybeBox))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Holder)]) : i64
  (match r.o
    [(MaybeBox.Some b) (sink b)]
    [(MaybeBox.None) 0]))

(define (main) : i64
  (let
    [h : Holder (Holder (MaybeBox.Some (box 42)))]
    (take (&mut h))))