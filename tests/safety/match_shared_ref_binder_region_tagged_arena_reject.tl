;; A `&` under an arena's region tag is rejected the same way (#9753).
(import stdlib.arena)

(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (:lifetimes a)
  (Some (in a (& program Holder)) (Box i64))
  (None))

(defstruct Outer
  (:lifetimes a)
  (slot (Slot a)))

(define (write [o : (& q (arena.Arena a))] [r : (&mut r (Outer a))]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)