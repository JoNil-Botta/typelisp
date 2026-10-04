;: A borrowed temporary is accepted only as a direct call argument.
(defstruct Point
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [p (& (Point 1 2))]
    p.x))