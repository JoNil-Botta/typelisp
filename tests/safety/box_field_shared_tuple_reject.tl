;; A Box element of a tuple field reached through a shared reference cannot be
;; bound as an owned Box (#8927).
(defstruct Holder
  (pair (Tuple (Box i64) i64)))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b : (Box i64) (tuple-ref r.pair 0)]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (tuple (box 40) 0))]
    (mutate (& h))
    (deref (tuple-ref h.pair 0))))