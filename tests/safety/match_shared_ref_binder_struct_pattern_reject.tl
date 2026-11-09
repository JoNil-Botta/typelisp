;; A `&` struct field bound by a pattern (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defstruct Keep
  (h (& program Holder))
  (k (Box i64)))

(defenum Slot
  (Some Keep)
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some (Keep s _k))
      (set! (deref s.b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)