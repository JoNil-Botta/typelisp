;; Returning a view of a field read through `&mut` as its owned value (#9646).
(defstruct Holder
  (b (Box i64)))

(define (take [r : (&mut r Holder)]) : (Box i64)
  (let
    [b : (Box i64) r.b]
    b))

(define (main) : i64
  (let
    [h : Holder (Holder (box 42))]
    (deref (take (&mut h)))))