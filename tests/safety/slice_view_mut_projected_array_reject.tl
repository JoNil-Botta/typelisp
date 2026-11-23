(defstruct Point
  (x i64))

(defstruct Buffer
  (items (Array Point 2)))

(define (overlap [b : (&mut a Buffer)]) : i64
  (let
    [left : (&mut a (Slice Point)) (slice-mut-view b.items 0 2)]
    [right : (&mut a (Slice Point)) (slice-mut-view b.items 0 2)]
    (set! (array-ref left 0) (Point 1))
    (set! (array-ref right 0) (Point 2))
    0))

(define (main) : i64
  0)