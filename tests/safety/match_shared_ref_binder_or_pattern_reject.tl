;; A binding or-pattern binds the same `&` (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (First (& program Holder) (Box i64))
  (Second (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(or (Slot.First s _k) (Slot.Second s _k))
      (set! (deref s.b) 1)
      0]
    [_ 0]))

(define (main) : i64
  0)