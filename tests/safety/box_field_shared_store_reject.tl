;; Storing a Box view into an owned place moves the caller's box out of the
;; shared reference: here into a field of a holder reached through `&mut`
;; (#8927).
(defstruct Holder
  (b (Box i64)))

(define (copy-into [out : (&mut out Holder)] [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (set! out.b b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    [o : Holder (Holder (box 0))]
    (copy-into (&mut o) (& h))
    (set! (deref o.b) 42)
    (deref h.b)))