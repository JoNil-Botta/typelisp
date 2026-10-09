(defstruct Point
  (x i64)
  (y i64))

(define (sum [point : (& point Point)]) : i64
  (match point
    [(tuple x y) (+ x y)]))

(define (main) : i64
  (let
    [point : Point (Point 40 2)]
    (sum (& point))))