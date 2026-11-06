;; An unannotated binding of a Box field read through a shared reference is a
;; view of the caller's box: writing its contents writes through the shared
;; reference (#8927).
(defstruct Holder
  (b (Box i64)))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b r.b]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (box 40))]
    (mutate (& h))
    (deref h.b)))