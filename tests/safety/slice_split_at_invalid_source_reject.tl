(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [halves (slice-split-at-mut items 1)]
    (array-length (tuple-ref halves 0))))