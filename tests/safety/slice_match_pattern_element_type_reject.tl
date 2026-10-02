(define (first-is-one [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice "one" & _) 1]
    [_ 0]))

(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (first-is-one (& items))))