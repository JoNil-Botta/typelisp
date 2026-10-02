(define (pair-sum [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice a b & _) (+ a b)]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (pair-sum (& items))))