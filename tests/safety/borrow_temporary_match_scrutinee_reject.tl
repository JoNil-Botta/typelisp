;: A borrowed temporary is not a match scrutinee; bind the value first.
(defenum Shape
  (Circle i64)
  (Empty))

(define (make) : Shape
  (Shape.Circle 3))

(define (main) : i64
  (match (& (make))
    [(Shape.Circle r) r]
    [(Shape.Empty) 0]))