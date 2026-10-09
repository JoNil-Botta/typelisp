(define (head [xs : (& (Slice i64))]) : i64
  (match xs
    [(or (slice x & _) (slice & x)) 1]))

(define (main) : i64
  0)