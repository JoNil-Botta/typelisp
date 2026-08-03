(define (main) : i64
  (let
    [a : (Array i64 1) (array 1)]
    (array-length (slice-view a 0))))