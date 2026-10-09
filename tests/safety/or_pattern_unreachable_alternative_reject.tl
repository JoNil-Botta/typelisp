(defenum Op
  (Load i64)
  (Store i64)
  (Name String))

(define (dst [op : Op]) : i64
  (match op
    [(or _ (Store _)) 1]))

(define (main) : i64
  0)