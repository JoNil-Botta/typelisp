(define (short [xs : (& (Slice i64))]) : i64
  (match xs
    [(or (slice) (slice _)) 0]
    [(slice a _) a]))

(define (main) : i64
  0)