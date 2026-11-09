;; A nested field path behind the `&` binder is behind that reference too (#9753).
(defstruct Inner
  (x (Box i64)))

(defstruct Holder
  (b Inner)
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b.x) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)