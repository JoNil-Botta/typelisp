(defstruct Point
  (x i64)
  (y i64))

(define (sum [p : Point]) : i64
  (match p
    [(fields x [other x]) (+ x other)]))

(define (main) : i64
  0)