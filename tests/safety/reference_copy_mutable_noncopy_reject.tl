(defstruct Owned
  (value (Box i64))
  (padding (Array i64 4)))

(define (escape [p : (&mut loan Owned)]) : Owned
  (deref p))

(define (main) : i64
  0)