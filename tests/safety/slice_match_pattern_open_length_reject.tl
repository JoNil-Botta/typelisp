(define (head-or-zero [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice a) a]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (head-or-zero (& items))))