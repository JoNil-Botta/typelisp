;; `replace!` of a place behind the `&` binder writes through it (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (replace! (deref s.b) 2)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)