;; A view of a Box holding a struct: writing a field of its contents writes
;; through the shared reference (#8927).
(defstruct Point
  (x i64)
  (y i64))

(defstruct Holder
  (b (Box Point)))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (set! (deref b).x 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (box (Point 40 0)))]
    (mutate (& h))
    (deref h.b).x))