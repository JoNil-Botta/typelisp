(defenum Same
  (Same i64))

(define (main) : i64
  (match (Same.Same 42)
    [(Same.Same value) value]))