;; A Box field bound from a holder read through a shared reference keeps that
;; reference as its origin: writing the binding's contents would mutate the
;; caller's box, so it writes through the shared reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b : (Box i64) r.b]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))