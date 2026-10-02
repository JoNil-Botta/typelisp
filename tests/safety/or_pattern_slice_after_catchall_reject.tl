(define (head [xs : (& (Slice i64))]) : i64
  (match xs
    [(or (slice & _) (slice)) 1]))

(define (main) : i64
  0)