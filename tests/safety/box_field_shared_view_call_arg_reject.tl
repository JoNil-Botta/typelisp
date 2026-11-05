;; Passing a view of a Box field to an owned Box parameter moves the box out
;; of the shared reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (sink [b : (Box i64)]) : unit
  (set! (deref b) 42))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (sink b)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))