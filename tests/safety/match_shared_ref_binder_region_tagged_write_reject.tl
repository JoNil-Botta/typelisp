;; A `&` written under a region tag is still a `&`, not a view: a write through
;; the binder is rejected (#9753). SPEC 3.9 does not list references as
;; region-taggable; the checker admits the type.
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (in program (& program Holder)) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (write [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (set! (deref s.b) 41)
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)