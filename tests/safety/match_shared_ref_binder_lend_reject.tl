;; A `&mut` loan of a place behind the `&` binder is a mutable lend through it (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (& program Holder) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (poke [p : (&mut p (Box i64))]) : unit
  (set! (deref (deref p)) 1))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (poke (&mut s.b))
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)