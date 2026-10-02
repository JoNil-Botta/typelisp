(defstruct Point
  (x i64)
  (y i64))

(define (read-x [p : (Ptr Point)]) : i64
  (deref p).x)

(define (main) : i64
  0)