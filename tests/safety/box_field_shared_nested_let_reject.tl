;; The same write through a Box bound from a nested field reached through a
;; shared reference (#8927).
(defstruct Inner
  (b (Box i64)))

(defstruct Holder
  (inner Inner))

(define (mutate [r : (& r Holder)]) : unit
  (let
    [b : (Box i64) r.inner.b]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [h : Holder (Holder (Inner (box 40)))]
    (mutate (& h))
    (deref h.inner.b)))