;: A Copy field read through a shared reference is a plain copy: it joins an
;: owned value and is mutated locally without touching the referent.
(defstruct Point
  (x i64)
  (y i64))

(defstruct Shape
  (origin Point)
  (sides i64))

(define (pick [shape : (& shape Shape)] [fallback : Point] [use-origin : bool]) : i64
  (let
    [point : Point
      (if use-origin
        shape.origin
        fallback)]
    (begin
      (set! point.x 39)
      (+ point.x (+ shape.origin.y shape.origin.x)))))

(define (main) : i64
  (let
    [shape : Shape (Shape (Point 1 2) 4)]
    (pick (& shape) (Point 5 6) true)))