;; A view rebound by name keeps the `&` binder as its origin (#9753).
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
      (let
        [v : (Box i64) s.b]
        [w : (Box i64) v]
        (set! (deref w) 1))
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)