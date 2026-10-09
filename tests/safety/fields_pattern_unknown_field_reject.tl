(defstruct Point
  (x i64)
  (y i64))

(define (depth [p : Point]) : i64
  (match p
    [(fields z) z]))

(define (main) : i64
  0)