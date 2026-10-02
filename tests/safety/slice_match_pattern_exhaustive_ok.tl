(define (sum [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice x & rest) (+ x (sum rest))]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (sum (& items))))