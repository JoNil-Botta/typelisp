(define (shape [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice a & _) a]
    [(slice a b) (+ a b)]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (shape (& items))))