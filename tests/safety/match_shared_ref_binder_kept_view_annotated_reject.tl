;; A plain-annotated `let` keeps a view of the field, and that view's write is
;; still behind the `&` binder (#9753, D-C225 reopening probe).
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
        (set! (deref v) 1))
      0]
    [(Slot.None) 0]))

(define (main) : i64
  0)