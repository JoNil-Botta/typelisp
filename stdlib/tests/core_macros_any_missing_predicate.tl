(define (main) : i64
  (let
    [values : (Array i64 2) (array 1 2)]
    (if (any? [value (& values)])
      1
      0)))