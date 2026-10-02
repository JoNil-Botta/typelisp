(defstruct Point
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [point : Point (Point 1 2)]
    [p : (MutPtr Point)
      (unsafe
        (ptr-addr-of point))]
    (begin
      (set! (deref p).x 10)
      point.x)))