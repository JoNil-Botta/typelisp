(define (count [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice & rest) (array-length rest)]
    [(slice) 0]))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    (count (& items))))