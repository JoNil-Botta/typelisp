;; An owned scrutinee does not make the `&` payload writable (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : Outer]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)