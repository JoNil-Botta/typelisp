(defenum Op
  (Load i64)
  (Store i64)
  (Name String))

(define (dst [op : Op]) : i64
  (match op
    [(or (Load n) (Store n)) n]))

(define (main) : i64
  0)