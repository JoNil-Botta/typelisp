;: A constructed value that stores a borrow of a temporary would outlive it.
(defstruct Point
  (x i64)
  (y i64))

(defstruct View
  (:lifetimes a)
  (point (& a Point)))

(define (main) : i64
  (let
    [view (View (& (Point 1 2)))]
    view.point.x))