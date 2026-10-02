(defstruct Point
  (x i64)
  (y i64))

(define (write-x [p : (Ptr Point)]) : unit
  (unsafe
    (set! (deref p).x 10)))

(define (main) : i64
  0)