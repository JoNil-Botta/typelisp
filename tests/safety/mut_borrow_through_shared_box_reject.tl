;: Box contents are owned through the Box, so a `&mut` borrow of them through a
;: shared reference to the Box's owner is rejected (#8743).
(defstruct Holder
  (b (Box i64)))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [h : (& Holder)]) : i64
  (bump (&mut (deref h.b)))
  0)

(define (main) : i64
  (let
    [h (Holder (box 40))]
    (f (& h))
    (deref h.b)))