(defstruct Point
  (x i64)
  (y i64))

(define (write [p : (MutPtr Point)]) : unit
  (unsafe
    (set! (deref p) (Point 1 2))))

(define (main) : i64
  0)