(module format_owner_point)

(import stdlib.format)

(defstruct Point
  (label String)
  (x i64)
  (y i64))

(define (make [label : String] [x : i64] [y : i64]) : Point
  (Point label x y))

(define (to-string [value : (& value Point)]) : String
  (format.format "Point({}, {})" value.x value.y))