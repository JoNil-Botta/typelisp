(define (main) : i64
  (match 42
    [(box value) value]
    [_ 0]))