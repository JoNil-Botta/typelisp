;; A view bound by `let` and then matched gives the same `&` binder (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (let
    [v r.slot]
    (match v
      [(Slot.Some s _k)
        (set! (deref s.b) 1)
        0]
      [(Slot.None) 0])))

(define (main) : i64
  0)