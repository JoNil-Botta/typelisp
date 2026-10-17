;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Holder
  (b (Box i64)))

(define (take [r : (& r Holder)]) : (Box i64)
  r.b)

(define (main) : i64
  0)