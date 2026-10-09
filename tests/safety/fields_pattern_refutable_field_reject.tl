(defstruct Point
  (x i64)
  (y i64))

(define (origin-score [p : Point]) : i64
  (match p
    [(fields [0 x]) 1]
    [_ 0]))

(define (main) : i64
  0)