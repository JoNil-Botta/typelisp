;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Holder
  (b (Box i64)))

(define (consume [b : (Box i64)]) : i64
  (deref b))

(define (read [r : (& r Holder)]) : i64
  (consume r.b))

(define (main) : i64
  0)