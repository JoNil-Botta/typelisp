;; A nested pattern binds the same `&` (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defenum Wrap
  (Some Slot)
  (None))

(defstruct Outer
  (wrap Wrap))

(define (write [r : (&mut r Outer)]) : i64
  (match r.wrap
    [(Wrap.Some (Slot.Some s _k))
      (set! (deref s.b) 1)
      0]
    [_ 0]))

(define (main) : i64
  0)