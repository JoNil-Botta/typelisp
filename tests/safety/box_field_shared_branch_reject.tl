;; A Box field selected by a branch from a holder read through a shared
;; reference is moved out of that reference when the branch's result is an
;; owned Box (#8927).
(defstruct Holder
  (b (Box i64)))

(define (mutate [r : (& r Holder)] [take? : bool]) : unit
  (let
    [b : (Box i64)
      (if take?
        r.b
        (box 0))]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h) true)
    (deref h.b)))