;; Constructing from a view of a field read through `&mut` (#9646).
(defstruct Holder
  (b (Box i64)))

(defstruct Wrap
  (inner (Box i64)))

(define (take [r : (&mut r Holder)]) : Wrap
  (let
    [b : (Box i64) r.b]
    (Wrap b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 42))]
    (deref (take (&mut h)).inner)))