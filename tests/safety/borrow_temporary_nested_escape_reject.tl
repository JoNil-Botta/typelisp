;: The temporary dies with the inner call even when its result is passed
;: straight to another call.
(defstruct Point
  (x i64)
  (y i64))

(define (keep [p : (& Point)]) : (& Point)
  p)

(define (sum [p : (& Point)]) : i64
  (+ p.x p.y))

(define (main) : i64
  (sum (keep (& (Point 1 2)))))