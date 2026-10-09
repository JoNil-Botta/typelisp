(define (head [xs : (& (Slice i64))]) : i64
  (match xs
    [(or (slice x) (slice x & rest)) x]
    [(slice) 0]))

(define (main) : i64
  0)