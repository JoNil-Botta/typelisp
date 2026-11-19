;; A `&` held in a tuple element of the payload (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (Tuple (& program Holder) i64) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some t _k)
      (set! (deref (tuple-ref t 0).b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)