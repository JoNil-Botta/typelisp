(defstruct Point
  (x i64)
  (y i64))

(defenum Item
  (At Point))

(define (main) : i64
  (let
    [item : Item (At (Point 40 2))]
    (match (& item)
      [(At (Point x)) (deref x)])))