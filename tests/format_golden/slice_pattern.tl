(define (sum [xs : (& (Slice i64))]) : i64
  (match xs [(slice) 0]
    [(slice x &   rest) (+ x (sum rest))]))

(define (first-pair [rows : (& (Slice (& (Slice i64))))]) : i64
  (match rows
    [(slice (slice a b
        & _) &
        _) (+ a b)]
    [_ 0]))
