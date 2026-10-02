;; Profile fixture: full-mode vectors of a struct and of an enum instantiate
;; `(eq.eq S)`, whose generated body imports the already-loaded `stdlib.eq`.
(import stdlib.vector)

(defstruct Point
  (x i64)
  (y i64))

(defenum Shade
  (Light)
  (Dark))

(import (vector.vector Point) as points)
(import (vector.vector Shade) as shades)

(define (main) : i64
  (let
    [ps : points.Vec (points.new)]
    [ss : shades.Vec (shades.new)]
    (begin
      (points.push! ps (Point 40 2))
      (shades.push! ss (Dark))
      (if (and
        (points.contains? (& ps) (Point 40 2))
        (shades.contains? (& ss) (Dark)))
        42
        1))))