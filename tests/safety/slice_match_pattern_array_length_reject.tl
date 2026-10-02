(define (main) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (match (& items)
      [(slice a b) (+ a b)]
      [_ 0])))