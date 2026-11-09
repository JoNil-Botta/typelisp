;; A `&` payload with a named lifetime through a `&mut` root does not reach the
;; write: a match on this path has no ownership-graph representation yet, read
;; or write, so it stays rejected (#9753; the owned-scrutinee form is E0207).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (:lifetimes a)
  (Some (& a Holder) (Box i64))
  (None))

(defstruct Outer
  (:lifetimes a)
  (slot (Slot a)))

(define (write [h : (& h Holder)] [r : (&mut r (Outer h))]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b) 1)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)