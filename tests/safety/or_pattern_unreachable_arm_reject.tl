(defenum Op
  (Load i64)
  (Store i64)
  (Name String))

(define (dst [op : Op]) : i64
  (match op
    [(or (Load _) _) 1]
    [(Store _) 2]))

(define (main) : i64
  0)