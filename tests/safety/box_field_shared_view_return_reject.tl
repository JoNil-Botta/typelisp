;; Returning a view of a Box field as an owned Box moves it out of the shared
;; reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (take [r : (& r Holder)]) : (Box i64)
  (let
    [b r.b]
    b))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    [b : (Box i64) (take (& h))]
    (set! (deref b) 42)
    (deref h.b)))