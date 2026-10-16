;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Inner
  (pair (Tuple i64 (Box i64))))

(defstruct Outer
  (inner Inner))

(define (mutate [r : (& r Outer)]) : unit
  (let
    [b : (Box i64) (tuple-ref r.inner.pair 1)]
    (set! (deref b) 42)))

(define (main) : i64
  0)