;; Reads through a region-tagged `&` binder stay accepted (#9753 control).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defenum Slot
  (Some (in program (& program Holder)) (Box i64))
  (None))

(defstruct Outer
  (slot Slot))

(define (read [r : (&mut r Outer)]) : i64
  (match r.slot
    [(Slot.Some s _k)
      (let
        [v : (Box i64) s.b]
        (+ (deref s.c) (deref v)))]
    [(Slot.None) 0]))

(define (main) : i64
  0)