;; An unannotated `let` view of the field is behind the `&` binder too (#9753).
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
        [v s.b]
        (set! (deref v) 1))
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)