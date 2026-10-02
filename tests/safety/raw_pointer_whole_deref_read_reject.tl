(defstruct Point
  (x i64)
  (y i64))

(define (read [p : (MutPtr Point)]) : Point
  (unsafe
    (deref p)))

(define (main) : i64
  0)