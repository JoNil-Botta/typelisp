;; A `&` root is rejected the same way (#9753 control).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (& r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)