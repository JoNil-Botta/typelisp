(import "struct_match_pattern_geom.tl" module struct.match.geom as geom)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Pair
  (left Point)
  (right Point))

(defenum Shape
  (None)
  (At Point))

(define (sum-point [p : Point]) : i64
  (match p
    [(Point x y) (+ x y)]))

(define (sum-pair-ends [p : Pair]) : i64
  (match p
    [(Pair (Point left _) (Point _ right)) (+ left right)]))

(define (sum-shape [s : Shape]) : i64
  (match s
    [(None) 0]
    [(At (Point x y)) (+ x y)]))

(define (sum-qualified) : i64
  (let
    [p : geom.QPoint (geom.QPoint 6 7)]
    (match p
      [(geom.QPoint x y) (+ x y)])))

(define (main) : i64
  (begin
    (unless (= (sum-point (Point 20 22)) 42) (return 1))
    (unless
      (= (sum-pair-ends (Pair (Point 5 100) (Point 200 37))) 42)
      (return 2))
    (unless (= (sum-shape (At (Point 19 23))) 42) (return 3))
    (unless (= (sum-qualified) 13) (return 4))
    42))