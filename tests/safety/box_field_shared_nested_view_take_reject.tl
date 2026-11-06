;; Taking the contents of a view of a nested Box by value moves the inner box
;; out of the caller's holder, through the shared reference the view was read
;; through: the callee would then write the caller's box (#8927).
(defstruct Holder
  (b (Box (Box i64))))

(define (sink [b : (Box i64)]) : unit
  (set! (deref b) 42))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (sink (deref b))))

(define (main) : i64
  (let
    [h : Holder (Holder (box (box 40)))]
    (mutate (& h))
    (deref (deref h.b))))