;; A `&mut` reached through the `&` binder grants only shared access (#9753).
(defstruct Holder
  (m (&mut program (Box i64)))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref (deref s.m)) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)