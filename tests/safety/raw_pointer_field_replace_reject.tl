(defstruct Point
  (x i64)
  (y i64))

(define (swap-x [p : (MutPtr Point)]) : i64
  (unsafe
    (replace! (deref p).x 3)))

(define (main) : i64
  0)