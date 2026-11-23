(defstruct Point
  (x i64))

(define (points) : (Array Point 2)
  (array (Point 0) (Point 0)))

(define (main) : i64
  (with-arena
    a
    (let
      [items (points)]
      [left (slice-mut-view items 0 2)]
      [right (slice-mut-view items 0 2)]
      (set! (array-ref left 0) (Point 1))
      (length right))))