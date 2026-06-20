(defstruct Point
  (x i64)
  (y i64))

(defstruct Size
  (x i64)
  (y i64))

(define (main [p : Point]) : i64
  (match p
    [(Size x y) (+ x y)]))