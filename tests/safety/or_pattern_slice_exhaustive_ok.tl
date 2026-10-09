(define (short [xs : (& (Slice i64))]) : i64
  (match xs
    [(or (slice) (slice _)) 0]
    [(slice a _ & _) a]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (short (& items))))