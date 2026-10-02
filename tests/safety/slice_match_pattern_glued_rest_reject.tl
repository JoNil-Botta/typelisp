(define (head [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice a &rest) a]
    [_ 0]))

(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (head (& items))))