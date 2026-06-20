(defstruct Point
  (x i64)
  (y i64))

(define (main [p : Point]) : i64
  (match p
    [(Point 1 y) y]))