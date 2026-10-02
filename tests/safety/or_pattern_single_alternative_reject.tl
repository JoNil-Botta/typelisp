(defenum Op
  (Load i64)
  (Store i64)
  (Name String))

(define (dst [op : Op]) : i64
  (match op
    [(or (Load n)) n]
    [_ 0]))

(define (main) : i64
  0)