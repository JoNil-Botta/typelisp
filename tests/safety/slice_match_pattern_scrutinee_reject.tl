(define (main) : i64
  (match 5
    [(slice a & _) a]
    [_ 0]))