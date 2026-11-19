;; A region-tagged `&mut` payload has no ownership-graph representation yet, so
;; it fails closed (#9753 control).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (in program (&mut program Holder)) (Box i64))
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