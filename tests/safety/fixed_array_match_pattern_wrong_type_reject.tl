(define (main [items : (Tuple i64 i64)]) : i64
  (match items
    [(array first second) (+ first second)]))