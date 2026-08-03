(define (main) : i64
  (let
    [a : (Array i64 2) (array 1 2)]
    (array-length (slice-view a 1 9223372036854775807))))