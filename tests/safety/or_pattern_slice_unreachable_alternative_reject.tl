(define (short [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice a & _) a]
    [(or (slice) (slice _)) 0]))

(define (main) : i64
  0)